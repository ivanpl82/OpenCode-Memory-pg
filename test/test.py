#!/usr/bin/env python3
"""
test.py – Integration test for the memory-pg plugin pipeline.

Tests every layer without needing opencode running:
  1. Embedding API (NaN / qwen3-embedding)
  2. PostgreSQL connection + pgvector
  3. Insert + semantic search with cosine similarity
  4. Negative test (unrelated query)

Usage:
  python3 test/test.py
  python3 test/test.py --verbose

Exit code 0 = all checks passed.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

VERBOSE = "--verbose" in sys.argv
PASS = 0
FAIL = 0


def log_pass(msg):
    global PASS
    PASS += 1
    print(f"  \033[32m✓\033[0m {msg}")


def log_fail(msg):
    global FAIL
    FAIL += 1
    print(f"  \033[31m✗\033[0m {msg}")


def header(title):
    print(f"\n\033[1m{title}\033[0m")


def die(msg):
    print(f"\033[31mERROR:\033[0m {msg}")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

config_dir = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "opencode"
config_file = config_dir / "memory-pg.json"
opencode_config_file = config_dir / "opencode.jsonc"

if not config_file.exists():
    die(f"Config not found at {config_file}. Run install.sh first.")

with open(config_file) as f:
    cfg = json.load(f)

conn_string = cfg["connectionString"]
model = cfg.get("embeddingModel", "qwen3-embedding")
base_url = cfg.get("embeddingBaseUrl", "https://api.nan.builders/v1")
dims = cfg.get("embeddingDimensions", 4096)
threshold = cfg.get("similarityThreshold", 0.6)

api_key = os.environ.get("NAN_API_KEY", "")
if not api_key and opencode_config_file.exists():
    with open(opencode_config_file) as f:
        oc = json.load(f)
    api_key = oc.get("provider", {}).get("litellm", {}).get("options", {}).get("apiKey", "")

if not api_key:
    die("NAN_API_KEY not set and not found in opencode.jsonc")


# ---------------------------------------------------------------------------
# Helper: get embedding via NaN API
# ---------------------------------------------------------------------------

import urllib.request

def get_embedding(text: str) -> list[float]:
    data = json.dumps({"model": model, "input": text}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/embeddings",
        data=data,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "curl/8.4",
        },
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    return resp["data"][0]["embedding"]


# ---------------------------------------------------------------------------
# Helper: psql with a vector param (writes SQL to temp file to avoid "Argument list too long")
# ---------------------------------------------------------------------------

import tempfile
import atexit

TMPDIR = Path(tempfile.mkdtemp(prefix="memory_pg_test_"))
atexit.register(lambda: shutil.rmtree(TMPDIR, ignore_errors=True) if TMPDIR.exists() else None)
import shutil


def psql_execute(sql_template: str, vec: list[float] | None = None) -> str:
    """Execute SQL via psql, optionally replacing :VECTOR with a pgvector literal."""
    sql = sql_template
    if vec is not None:
        vec_str = "[" + ",".join(str(x) for x in vec) + "]"
        sql = sql.replace(":VECTOR", f"'{vec_str}'::vector")

    sql_file = TMPDIR / "query.sql"
    with open(sql_file, "w") as f:
        f.write(sql)

    result = subprocess.run(
        ["psql", conn_string, "-t", "-A", "-f", str(sql_file)],
        capture_output=True, text=True, timeout=30,
    )
    return result.stdout.strip()


def psql_execute_simple(sql: str) -> str:
    """Execute a simple SQL statement (no vector params)."""
    result = subprocess.run(
        ["psql", conn_string, "-t", "-A", "-c", sql],
        capture_output=True, text=True, timeout=30,
    )
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# 1. Embedding API
# ---------------------------------------------------------------------------

header("1. Embedding API")

try:
    emb = get_embedding("Hola mundo")
    assert len(emb) == dims, f"Expected {dims} dims, got {len(emb)}"
    log_pass(f"API responds with {dims}-dimensional vectors")
    if VERBOSE:
        print(f"    First 3 dims: {emb[:3]}")
except Exception as e:
    log_fail(f"Embedding API error: {e}")

# ---------------------------------------------------------------------------
# 2. PostgreSQL + pgvector
# ---------------------------------------------------------------------------

header("2. PostgreSQL + pgvector")

try:
    vec_ver = psql_execute_simple(
        "SELECT installed_version FROM pg_available_extensions WHERE name='vector'"
    )
    assert vec_ver, "pgvector not available"
    log_pass(f"pgvector version {vec_ver} installed")
except Exception as e:
    log_fail(f"pgvector check failed: {e}")

# ---------------------------------------------------------------------------
# 3. Insert + semantic search
# ---------------------------------------------------------------------------

header("3. Insert + semantic search")

# Insert
try:
    emb_insert = get_embedding("Al usuario le gusta que le hablen en castellano")
    psql_execute(
        """
        INSERT INTO memories (content, embedding, metadata, scope)
        VALUES (
            'Al usuario le gusta que le hablen en castellano',
            :VECTOR,
            '{"type":"preference","test":true}',
            'user'
        );
        """,
        emb_insert,
    )
    log_pass("Inserted test memory into PostgreSQL")
except Exception as e:
    log_fail(f"INSERT failed: {e}")

# Semantic search
try:
    emb_search = get_embedding("idioma español")
    result = psql_execute(
        """
        SELECT content, 1 - (embedding <=> :VECTOR) AS sim
        FROM memories
        WHERE metadata->>'test' = 'true'
          AND 1 - (embedding <=> :VECTOR) > {}
        ORDER BY sim DESC
        LIMIT 1;
        """.format(threshold),
        emb_search,
    )

    if result:
        parts = result.split("|")
        content = parts[0]
        sim = float(parts[1])
        log_pass(f'Semantic search found: "{content}" (sim: {sim})')
    else:
        log_fail(f"Semantic search returned no results (threshold {threshold} too high?)")
except Exception as e:
    log_fail(f"Search failed: {e}")

# ---------------------------------------------------------------------------
# 4. Negative test (unrelated query)
# ---------------------------------------------------------------------------

header("4. Negative test (unrelated query)")

try:
    emb_neg = get_embedding("programación en Python")
    neg_result = psql_execute(
        """
        SELECT 1 - (embedding <=> :VECTOR) AS sim
        FROM memories
        WHERE metadata->>'test' = 'true'
        ORDER BY sim DESC
        LIMIT 1;
        """,
        emb_neg,
    )

    if neg_result:
        neg_sim = float(neg_result)
        if neg_sim < threshold:
            log_pass(f"Unrelated query yields low similarity ({neg_sim} < {threshold})")
        else:
            log_fail(f"Unrelated query scored above threshold ({neg_sim})")
    else:
        log_pass("Unrelated query returns no results")
except Exception as e:
    log_fail(f"Negative test failed: {e}")

# ---------------------------------------------------------------------------
# 5. Cleanup
# ---------------------------------------------------------------------------

header("5. Cleanup")

try:
    psql_execute_simple("DELETE FROM memories WHERE metadata->>'test' = 'true'")
    log_pass("Test data cleaned up")
except Exception as e:
    log_fail(f"Cleanup failed: {e}")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print(f"\n\033[1mResults: {PASS} passed, {FAIL} failed\033[0m")
if FAIL == 0:
    print("\033[32m✓ TEST PASSED\033[0m")
else:
    print("\033[31m✗ TEST FAILED\033[0m")

sys.exit(FAIL)