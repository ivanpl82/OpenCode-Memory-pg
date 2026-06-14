import type { Plugin } from "@opencode-ai/plugin";
import { readFileSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import pg from "pg";

const { Pool } = pg;

// ---------------------------------------------------------------------------
// Config types & loading
// ---------------------------------------------------------------------------

interface Config {
  connectionString: string;
  embeddingModel: string;
  embeddingBaseUrl: string;
  embeddingDimensions: number;
  topK: number;
  similarityThreshold: number;
}

function loadConfig(): Config {
  const configPath = join(
    homedir(),
    ".config",
    "opencode",
    "memory-pg.json",
  );
  if (!existsSync(configPath)) {
    throw new Error(
      `Config file not found at ${configPath}. ` +
        "Run install.sh first, or create the file manually.",
    );
  }
  return JSON.parse(readFileSync(configPath, "utf-8"));
}

function resolveApiKey(): string {
  const fromEnv = process.env.NAN_API_KEY;
  if (fromEnv) return fromEnv;

  const configPath = join(
    homedir(),
    ".config",
    "opencode",
    "opencode.jsonc",
  );
  try {
    const raw = readFileSync(configPath, "utf-8");
    const parsed = JSON.parse(raw);
    const key = parsed.provider?.litellm?.options?.apiKey;
    if (key) return key;
  } catch {}

  throw new Error(
    "NAN_API_KEY env var is not set and could not be read from opencode.jsonc.",
  );
}

function getProjectHash(): string | undefined {
  try {
    return Buffer.from(process.cwd()).toString("hex").slice(0, 16);
  } catch {
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

export default (async () => {
  const config = loadConfig();
  const apiKey = resolveApiKey();

  const {
    connectionString,
    embeddingModel,
    embeddingBaseUrl,
    embeddingDimensions,
    topK,
    similarityThreshold,
  } = config;

  const pool = new Pool({ connectionString });

  // ---- helpers ------------------------------------------------------------

  async function getEmbedding(text: string): Promise<number[]> {
    const res = await fetch(`${embeddingBaseUrl}/embeddings`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "User-Agent": "opencode-memory-pg/1.0",
      },
      body: JSON.stringify({ model: embeddingModel, input: text }),
    });
    if (!res.ok) {
      throw new Error(
        `Embedding API error ${res.status}: ${await res.text()}`,
      );
    }
    const data: any = await res.json();
    return data.data[0].embedding;
  }

  async function queryMemories(
    embedding: number[],
    scope: string,
    projectHash?: string,
  ) {
    const vec = `[${embedding.join(",")}]`;
    const result = await pool.query(
      `
        SELECT id, content, metadata, scope, project_hash, created_at,
               1 - (embedding <=> $1::halfvec) AS similarity
        FROM memories
        WHERE scope = $2
          AND ($3::text IS NULL OR project_hash = $3)
          AND 1 - (embedding <=> $1::halfvec) > $4
        ORDER BY embedding <=> $1::halfvec
        LIMIT $5
      `,
      [vec, scope, projectHash ?? null, similarityThreshold, topK],
    );
    return result.rows;
  }

  // ---- initialise database ------------------------------------------------

  await pool.query(`
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE TABLE IF NOT EXISTS memories (
      id           SERIAL PRIMARY KEY,
      content      TEXT NOT NULL,
      embedding    halfvec(${embeddingDimensions}),
      metadata     JSONB DEFAULT '{}',
      scope        TEXT NOT NULL DEFAULT 'user',
      project_hash TEXT,
      created_at   TIMESTAMPTZ DEFAULT NOW(),
      updated_at   TIMESTAMPTZ DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS idx_memories_scope
      ON memories (scope, project_hash);
    CREATE INDEX IF NOT EXISTS idx_memories_embedding_hnsw
      ON memories USING hnsw (embedding halfvec_cosine_ops);
  `);

  // ---- state ----------------------------------------------------------------

  let memoryInjected = false;

  // ---------------------------------------------------------------------------
  // Hook handlers
  // ---------------------------------------------------------------------------

  return {
    tool: {
      "memory-search": {
        description:
          "Search long-term memory for relevant information using semantic similarity. " +
          "Use when the user asks about past conversations, preferences, or project knowledge.",
        args: {
          query: "string - The text query to search for",
          scope:
            "string - Optional: 'user' (cross-project) or 'project' (this project only)",
        },
        async execute(args: { query: string; scope?: string }) {
          const scope = args.scope || "user";
          const projectHash =
            scope === "project" ? getProjectHash() : undefined;
          const embedding = await getEmbedding(args.query);
          return JSON.stringify(
            await queryMemories(embedding, scope, projectHash),
          );
        },
      },

      "memory-add": {
        description:
          "Store a new piece of information in long-term memory. " +
          "Use when the user says 'remember', 'save', \"don't forget\", " +
          "or explicitly asks to store something.",
        args: {
          content: "string - The information to remember",
          type:
            "string - Optional category: project-config, architecture, " +
            "error-solution, preference, learned-pattern, conversation",
          scope:
            "string - Optional: 'user' (cross-project) or 'project' (this project only)",
        },
        async execute(args: {
          content: string;
          type?: string;
          scope?: string;
        }) {
          const scope = args.scope || "user";
          const projectHash =
            scope === "project" ? getProjectHash() : undefined;
          const embedding = await getEmbedding(args.content);
          const metadata = JSON.stringify({
            type: args.type || "general",
            added_at: new Date().toISOString(),
          });
          const result = await pool.query(
            `INSERT INTO memories (content, embedding, metadata, scope, project_hash)
             VALUES ($1, $2, $3, $4, $5) RETURNING id`,
            [
              args.content,
              `[${embedding.join(",")}]`,
              metadata,
              scope,
              projectHash,
            ],
          );
          return JSON.stringify({
            id: result.rows[0].id,
            status: "saved",
          });
        },
      },

      "memory-delete": {
        description: "Delete a memory by its ID.",
        args: { id: "number - The ID of the memory to delete" },
        async execute(args: { id: number }) {
          await pool.query("DELETE FROM memories WHERE id = $1", [args.id]);
          return JSON.stringify({ status: "deleted", id: args.id });
        },
      },

      "memory-list": {
        description:
          "List recent memories, optionally filtered by scope.",
        args: {
          scope:
            "string - Optional: 'user' or 'project' (default: 'user')",
          limit: "number - Optional: max results (default 10)",
        },
        async execute(args: { scope?: string; limit?: number }) {
          const scope = args.scope || "user";
          const limit = args.limit || 10;
          const projectHash =
            scope === "project" ? getProjectHash() : undefined;
          const result = await pool.query(
            `SELECT id, content, metadata, scope, project_hash, created_at
             FROM memories
             WHERE scope = $1
               AND ($2::text IS NULL OR project_hash = $2)
             ORDER BY created_at DESC
             LIMIT $3`,
            [scope, projectHash ?? null, limit],
          );
          return JSON.stringify(result.rows);
        },
      },
    },

    "chat.message": async (_input, output) => {
      const userPart = output.parts.find((p: any) => p.type === "text");
      if (!userPart?.text) return;

      const msg = userPart.text;

      // ---- keyword detection ------------------------------------------------

      const keywords = [
        /recuerda/i,
        /guarda/i,
        /no olvides/i,
        /remember/i,
        /save this/i,
        /don't forget/i,
      ];
      if (keywords.some((p) => p.test(msg))) {
        output.parts.push({
          type: "text",
          text:
            "[MEMORY TRIGGER] The user wants to save something. " +
            "Use memory-add to store it.",
          synthetic: true,
        });
      }

      // ---- context injection (once per session) ----------------------------

      if (memoryInjected) return;
      memoryInjected = true;

      try {
        const embedding = await getEmbedding(msg);
        const projectHash = getProjectHash();

        const [userRows, projectRows] = await Promise.all([
          queryMemories(embedding, "user"),
          projectHash
            ? queryMemories(embedding, "project", projectHash)
            : Promise.resolve([]),
        ]);

        const all = [...userRows, ...projectRows];
        if (all.length > 0) {
          output.parts.unshift({
            type: "text",
            text:
              "\n[RELEVANT MEMORIES]\n" +
              all.map((r: any) => `- [${r.scope}] ${r.content}`).join("\n"),
            synthetic: true,
          });
        }
      } catch (e) {
        console.error("[memory-pg] context injection error:", e);
      }
    },

    "experimental.session.compacting": async (_input, output) => {
      try {
        const projectHash = getProjectHash();
        const result = await pool.query(
          `SELECT content FROM memories
           WHERE scope = 'project' AND project_hash = $1
           LIMIT 10`,
          [projectHash],
        );
        if (result.rows.length > 0) {
          const ctx =
            "\n## Project Knowledge\n" +
            result.rows.map((r: any) => `- ${r.content}`).join("\n");
          if (output.context) {
            output.context.push(ctx);
          } else if (output.prompt) {
            output.prompt += ctx;
          }
        }
      } catch (e) {
        console.error("[memory-pg] compaction error:", e);
      }
    },
  };
}) satisfies Plugin;
