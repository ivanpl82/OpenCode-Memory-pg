# opencode-memory-pg

Plugin de memoria a largo plazo para [opencode](https://opencode.ai) usando PostgreSQL + pgvector.

Guarda recuerdos, preferencias y conocimiento del proyecto en tu propia base de datos PostgreSQL con búsqueda semántica por vectores (embeddings). Todo funciona en local — tus datos no salen de tu máquina.

---

## Requisitos

| Recurso | Versión mínima | Notas |
|---|---|---|
| PostgreSQL | 14+ | Cualquier versión con pgvector, o usa el contenedor Docker incluido |
| pgvector | 0.5+ | Extensión para vectores (incluida en el contenedor Docker) |
| NaN API key | — | La misma que usas para el chat en opencode |
| opencode | 1.17+ | — |
| `python3` | cualquier | Para los scripts (incluido en la mayoría de distros) |

### PostgreSQL

Hay dos opciones:

**Opción A — Contenedor Docker (recomendado):** El instalador puede levantar un contenedor con PostgreSQL + pgvector automáticamente. Solo necesitas tener Docker y Docker Compose instalados.

**Opción B — Instancia existente:** Si ya tienes PostgreSQL, la extensión pgvector debe estar instalada:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

Verifica que está disponible:

```bash
psql -c "SELECT installed_version FROM pg_available_extensions WHERE name='vector'"
```

---

## Instalación

### Automática (recomendada)

```bash
cd plugin_opencode_memory
bash install.sh
```

El script te guiará interactivamente:

0. Detecta tu distribución Linux y el gestor de paquetes
1. Verifica los binarios necesarios (`python3`, `npm`, `curl`, `psql`, `docker`) y te ofrece instalarlos si faltan
2. Te pregunta si quieres usar **PostgreSQL en Docker** (contenedor en `./Docker/`) o una instancia existente
   - Si eliges Docker: levanta el contenedor, espera a que esté listo y configura la connection string automáticamente
   - Si eliges manual: te pide la connection string de PostgreSQL
3. Instala la dependencia `pg` en el directorio de configuración de opencode
4. Copia el plugin y el archivo de configuración
5. Crea la tabla `memories` en la base de datos
6. Añade la entrada del plugin en `opencode.jsonc`
7. Verifica que la API de embeddings de NaN responde correctamente

Para instalación no interactiva (usa valores por defecto):

```bash
bash install.sh --yes
```

### Manual

1. **Instalar dependencias**:

   ```bash
   cd ~/.config/opencode
   npm install pg
   cd -
   ```

2. **Copiar el plugin**:

   ```bash
   mkdir -p ~/.config/opencode/plugins
   cp src/memory-pg.ts ~/.config/opencode/plugins/memory-pg.ts
   ```

3. **Crear configuración**:

   ```bash
   cp config/memory-pg.json ~/.config/opencode/memory-pg.json
   ```

   Edita `~/.config/opencode/memory-pg.json` y cambia `connectionString` con tus datos:

   ```json
   {
     "connectionString": "postgresql://usuario:contraseña@127.0.0.1:5432/contexto",
     "embeddingModel": "qwen3-embedding",
     "embeddingBaseUrl": "https://api.nan.builders/v1",
     "embeddingDimensions": 4096,
     "topK": 5,
     "similarityThreshold": 0.6
   }
   ```

4. **Crear tabla en PostgreSQL**:

   ```bash
   psql "tu_connection_string" -c "
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE TABLE IF NOT EXISTS memories (
     id           SERIAL PRIMARY KEY,
     content      TEXT NOT NULL,
     embedding    vector(4096),
     metadata     JSONB DEFAULT '{}',
     scope        TEXT NOT NULL DEFAULT 'user',
     project_hash TEXT,
     created_at   TIMESTAMPTZ DEFAULT NOW(),
     updated_at   TIMESTAMPTZ DEFAULT NOW()
   );
   CREATE INDEX IF NOT EXISTS idx_memories_scope ON memories (scope, project_hash);
   "
   ```

5. **Registrar en opencode**:

   Añade a `~/.config/opencode/opencode.jsonc`:

   ```json
   "plugin": [
     "./plugins/memory-pg.ts"
   ]
   ```

6. **API Key**: Asegúrate de tener la API key de NaN. El plugin la lee automáticamente de tu opencode.jsonc o de la variable de entorno `NAN_API_KEY`.

7. **Reinicia opencode**.

---

## Configuración

Archivo: `~/.config/opencode/memory-pg.json`

| Campo | Por defecto | Descripción |
|---|---|---|
| `connectionString` | — | URI de conexión a PostgreSQL con pgvector (ej: `postgresql://usuario:contraseña@host:5432/contexto`) |
| `embeddingModel` | `qwen3-embedding` | Modelo de embeddings de NaN |
| `embeddingBaseUrl` | `https://api.nan.builders/v1` | Base URL de la API de NaN |
| `embeddingDimensions` | `4096` | Dimensiones del vector (debe coincidir con el modelo) |
| `topK` | `5` | Número máximo de memorias a recuperar por búsqueda |
| `similarityThreshold` | `0.6` | Umbral mínimo de similitud (0-1) para considerar un resultado relevante |

### API Key

El plugin busca la API key en este orden:

1. Variable de entorno `NAN_API_KEY`
2. `provider.litellm.options.apiKey` en `~/.config/opencode/opencode.jsonc`

---

## Herramientas disponibles

Una vez instalado, opencode dispondrá de estas herramientas:

### `memory-search`
Busca memorias por similitud semántica.

- `query` — texto a buscar
- `scope` — `"user"` (global) o `"project"` (solo proyecto actual)

### `memory-add`
Guarda información en la memoria a largo plazo.

- `content` — texto a recordar
- `type` — categoría: `preference`, `architecture`, `error-solution`, `conversation`, etc.
- `scope` — `"user"` o `"project"`

### `memory-delete`
Elimina una memoria por su ID.

### `memory-list`
Lista memorias recientes.

- `scope` — filtro por ámbito
- `limit` — máximo de resultados

---

## Cómo funciona

```
Usuario: "Recuerda que prefiero respuestas en español"
  → Plugin detecta palabra clave "recuerda"
  → Agente llama a memory-add("prefiero respuestas en español")
  → El plugin embeddea el texto vía NaN API (qwen3-embedding, 4096 dims)
  → Guarda vector en PostgreSQL con pgvector

[Sesión nueva, días después]
Usuario: "¿En qué idioma prefieres responderme?"
  → Plugin embeddea la pregunta
  → Busca similitud coseno en la tabla memories
  → Encuentra la memoria con 94% de similitud
  → La inyecta como contexto invisible
  → El agente responde en español sin que el usuario tenga que repetirlo
```

### Pipeline

1. **Inyección automática de contexto** — Al inicio de cada sesión, el plugin busca memorias relevantes al mensaje del usuario y las inyecta como `synthetic: true` (invisibles para el usuario pero visibles para el agente).
2. **Detección de palabras clave** — Cuando el usuario dice "recuerda", "guarda", "no olvides", etc., el plugin añade una señal para que el agente use `memory-add`.
3. **Compactación** — Cuando opencode compacta la conversación, el plugin inyecta las memorias del proyecto para que no se pierdan en el resumen.

---

## Tests

```bash
python3 test/test.py
# o
bash test/test.sh
```

El test verifica:

1. **API de embeddings** — que NaN responde con vectores de 4096 dimensiones
2. **PostgreSQL + pgvector** — que la base de datos está accesible y pgvector instalado
3. **Inserción + búsqueda semántica** — inserta un texto de prueba y lo recupera por similitud coseno
4. **Test negativo** — verifica que una consulta no relacionada no produce falso positivo
5. **Limpieza** — elimina los datos de prueba

Para ver respuestas detalladas:

```bash
python3 test/test.py --verbose
```

---

## Estructura del proyecto

```
plugin_opencode_memory/
├── package.json           # Dependencias (pg, @opencode-ai/plugin, typescript)
├── tsconfig.json          # TypeScript strict mode
├── .gitignore
├── README.md              # Esta documentación
├── install.sh             # Script de instalación automática
├── uninstall.sh           # Script de desinstalación
├── Docker/
│   ├── docker-compose.yml # Contenedor PostgreSQL + pgvector
│   └── init-user.sql      # Creación de usuario y base de datos
├── src/
│   └── memory-pg.ts       # Código del plugin
├── config/
│   └── memory-pg.json     # Template de configuración
└── test/
    └── test.sh            # Test de integración del pipeline completo
```

---

## Desinstalación

```bash
bash uninstall.sh
```

El script:
1. Elimina `~/.config/opencode/plugins/memory-pg.ts`
2. Elimina `~/.config/opencode/memory-pg.json`
3. Quita la entrada del plugin de `opencode.jsonc` (con backup automático)
4. Pregunta si quieres borrar la tabla `memories` de PostgreSQL

---

## Notas técnicas

### Índice HNSW con halfvec

El modelo `qwen3-embedding` genera vectores de 4096 dimensiones. Hasta pgvector 0.7.0 se usaba el tipo `vector` (float32), limitado a 2000 dimensiones para índices. Ahora se usa el tipo `halfvec` (float16), que soporta índices HNSW hasta 4000 dimensiones sin pérdida significativa de precisión.

El plugin y el instalador crean automáticamente:

```sql
CREATE INDEX IF NOT EXISTS idx_memories_embedding_hnsw
  ON memories USING hnsw (embedding halfvec_cosine_ops);
```

Esto permite búsqueda aproximada por similitud coseno con buen rendimiento incluso con miles de memorias.

### Embeddings

Se usa la API de NaN (`POST /v1/embeddings`) con el modelo `qwen3-embedding`. Es compatible con la API de OpenAI, así que si cambias de proveedor solo necesitas actualizar `embeddingBaseUrl`, `embeddingModel` y `embeddingDimensions`.

### Dependencias

- **Runtime**: `pg` (driver PostgreSQL) — se instala en `~/.config/opencode/node_modules/` donde Bun (el runtime de opencode) lo resuelve automáticamente.
- **Dev**: `@opencode-ai/plugin` (tipos TypeScript), `@types/pg`, `typescript`.