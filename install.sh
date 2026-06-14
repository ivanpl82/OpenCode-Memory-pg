#!/usr/bin/env bash
#
# install.sh – Install (or reinstall) the memory-pg plugin for opencode.
#
# What it does:
#   1. Detects your Linux distro and maps package manager
#   2. Checks prerequisites (psql, python3, npm, curl, docker)
#      and offers to install any that are missing
#   3. Asks if you want to use PostgreSQL in Docker (./Docker)
#      or an existing PostgreSQL instance
#   4. Installs npm dependencies in ~/.config/opencode/node_modules
#   5. Copies src/memory-pg.ts → ~/.config/opencode/plugins/memory-pg.ts
#   6. Creates/updates config in ~/.config/opencode/memory-pg.json
#   7. Creates the memories table in PostgreSQL
#   8. Adds "plugin" entry to opencode.jsonc if missing
#   9. Verifies the NaN embedding API responds
#
# Usage:
#   bash install.sh               # interactive
#   bash install.sh --yes         # non-interactive, accept defaults
#
# ---------------------------------------------------------------------------

set -euo pipefail

INTERACTIVE=true
[[ "${1:-}" == "--yes" ]] && INTERACTIVE=false

OPENCODE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DEST="$OPENCODE_CONFIG_DIR/plugins/memory-pg.ts"
CONFIG_DEST="$OPENCODE_CONFIG_DIR/memory-pg.json"
OPENCODE_MAIN_CONFIG="$OPENCODE_CONFIG_DIR/opencode.jsonc"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

USE_DOCKER=false
DOCKER_COMPOSE_CMD=""

echo -e "\033[1m━━━ memory-pg plugin installer ━━━\033[0m"
echo

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------

PKG_MGR=""
INSTALL_CMD=""
PSQL_PKG=""
PYTHON_PKG=""
NPM_PKG=""
CURL_PKG=""
DOCKER_PKG=""
DOCKER_COMPOSE_PKG=""

detect_distro() {
  if [[ ! -f /etc/os-release ]]; then
    echo -e "  \033[33m⚠\033[0m Cannot detect distro (/etc/os-release not found)"
    echo "    Proceeding without auto-install support."
    return
  fi
  source /etc/os-release

  case "$ID" in
    ubuntu|debian|linuxmint|pop|elementary|kali|neon|zorin)
      PKG_MGR="apt-get"
      PSQL_PKG="postgresql-client"
      PYTHON_PKG="python3"
      NPM_PKG="npm"
      CURL_PKG="curl"
      DOCKER_PKG="docker.io"
      DOCKER_COMPOSE_PKG="docker-compose-plugin"
      ;;
    fedora)
      PKG_MGR="dnf"
      PSQL_PKG="postgresql"
      PYTHON_PKG="python3"
      NPM_PKG="npm"
      CURL_PKG="curl"
      DOCKER_PKG="docker"
      DOCKER_COMPOSE_PKG="docker-compose"
      ;;
    rhel|centos|rocky|almalinux)
      PKG_MGR="dnf"
      PSQL_PKG="postgresql"
      PYTHON_PKG="python3"
      NPM_PKG="npm"
      CURL_PKG="curl"
      DOCKER_PKG="docker"
      DOCKER_COMPOSE_PKG="docker-compose"
      ;;
    arch|manjaro|endeavouros|artix|garuda)
      PKG_MGR="pacman"
      PSQL_PKG="postgresql"
      PYTHON_PKG="python"
      NPM_PKG="npm"
      CURL_PKG="curl"
      DOCKER_PKG="docker"
      DOCKER_COMPOSE_PKG="docker-compose"
      ;;
    opensuse*|suse|sles)
      PKG_MGR="zypper"
      PSQL_PKG="postgresql"
      PYTHON_PKG="python3"
      NPM_PKG="npm"
      CURL_PKG="curl"
      DOCKER_PKG="docker"
      DOCKER_COMPOSE_PKG="docker-compose"
      ;;
    alpine)
      PKG_MGR="apk"
      PSQL_PKG="postgresql-client"
      PYTHON_PKG="python3"
      NPM_PKG="npm"
      CURL_PKG="curl"
      DOCKER_PKG="docker"
      DOCKER_COMPOSE_PKG="docker-compose"
      ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*)
          PKG_MGR="apt-get"
          PSQL_PKG="postgresql-client"
          PYTHON_PKG="python3"
          NPM_PKG="npm"
          CURL_PKG="curl"
          DOCKER_PKG="docker.io"
          DOCKER_COMPOSE_PKG="docker-compose-plugin"
          ;;
        *fedora*|*rhel*)
          PKG_MGR="dnf"
          PSQL_PKG="postgresql"
          PYTHON_PKG="python3"
          NPM_PKG="npm"
          CURL_PKG="curl"
          DOCKER_PKG="docker"
          DOCKER_COMPOSE_PKG="docker-compose"
          ;;
        *arch*)
          PKG_MGR="pacman"
          PSQL_PKG="postgresql"
          PYTHON_PKG="python"
          NPM_PKG="npm"
          CURL_PKG="curl"
          DOCKER_PKG="docker"
          DOCKER_COMPOSE_PKG="docker-compose"
          ;;
      esac
      ;;
  esac

  if [[ -n "$PKG_MGR" ]]; then
    INSTALL_CMD="sudo $PKG_MGR install -y"
    echo -e "  \033[32m✓\033[0m Detected: $ID (package manager: $PKG_MGR)"
  else
    echo -e "  \033[33m⚠\033[0m Distro '$ID' not recognised. Proceeding without auto-install."
  fi
  echo
}

# ---------------------------------------------------------------------------
# JSON helper (python3, no jq needed)
# ---------------------------------------------------------------------------

json_get() {
  python3 -c "import json,sys; d=json.load(open('$1')); print(d$2)" 2>/dev/null || echo ""
}

json_set() {
  python3 -c "
import json
d=json.load(open('$1'))
d$2
json.dump(d,open('$1','w'),indent=2)
"
}

# ---------------------------------------------------------------------------
# Helper: ensure a binary is available, offer to install if missing
# ---------------------------------------------------------------------------

ensure_bin() {
  local bin="$1" pkg="$2" label="$3"
  if command -v "$bin" &>/dev/null; then
    echo -e "  \033[32m✓\033[0m $label found"
    return 0
  fi

  echo -e "  \033[31m✗\033[0m $label is required but not installed."

  if [[ -z "$INSTALL_CMD" || -z "$pkg" ]]; then
    echo "    Install it manually and re-run this script."
    return 1
  fi

  echo -n "    Install $pkg with '$INSTALL_CMD $pkg'? [Y/n] "
  local reply="Y"
  if $INTERACTIVE; then read -r reply; reply="${reply:-Y}"; fi
  if [[ "$reply" =~ ^[Yy] ]]; then
    echo "    Running: $INSTALL_CMD $pkg"
    $INSTALL_CMD "$pkg" 2>/dev/null || {
      echo -e "  \033[31m✗\033[0m Failed to install $pkg. Install it manually."
      return 1
    }
    if command -v "$bin" &>/dev/null; then
      echo -e "  \033[32m✓\033[0m $label installed successfully"
      return 0
    else
      echo -e "  \033[31m✗\033[0m $bin still not found after install. Check manually."
      return 1
    fi
  else
    echo "    Aborting. Install $pkg manually and re-run."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: check Docker Compose availability
# ---------------------------------------------------------------------------

detect_docker_compose() {
  DOCKER_COMPOSE_CMD=""
  if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
    return 0
  fi
  if command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 0.  Distro detection
# ---------------------------------------------------------------------------

echo -e "\033[1m0. Detecting distribution\033[0m"
detect_distro

# ---------------------------------------------------------------------------
# 1.  Prerequisites
# ---------------------------------------------------------------------------

echo -e "\033[1m1. Checking prerequisites\033[0m"

MISSING=false

ensure_bin "python3" "$PYTHON_PKG" "python3" || MISSING=true
ensure_bin "npm"     "$NPM_PKG"     "npm"     || MISSING=true
ensure_bin "curl"    "$CURL_PKG"    "curl"    || MISSING=true

if $MISSING; then
  echo "  Essential tools missing. Install them and re-run."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1b.  opencode config directory
# ---------------------------------------------------------------------------

if [[ ! -d "$OPENCODE_CONFIG_DIR" ]]; then
  echo -e "  \033[33m⚠\033[0m opencode config dir not found at $OPENCODE_CONFIG_DIR"
  echo -n "    Create it? [Y/n] "
  if $INTERACTIVE; then read -r reply; reply="${reply:-Y}"; else reply="Y"; fi
  if [[ "$reply" =~ ^[Yy] ]]; then
    mkdir -p "$OPENCODE_CONFIG_DIR"
    echo -e "  \033[32m✓\033[0m Created $OPENCODE_CONFIG_DIR"
  else
    echo "  Aborting."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1c.  Docker or manual PostgreSQL?
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m2. PostgreSQL setup\033[0m"

DOCKER_AVAILABLE=false
if command -v docker &>/dev/null && detect_docker_compose; then
  DOCKER_AVAILABLE=true
fi

if $DOCKER_AVAILABLE; then
  echo -n "  Use PostgreSQL in Docker (container in ./Docker)? [Y/n] "
  reply="Y"
  if $INTERACTIVE; then read -r reply; reply="${reply:-Y}"; else reply="N"; fi
else
  echo -e "  \033[33m⚠\033[0m Docker not detected. Using manual PostgreSQL setup."
  reply="N"
fi

CONN_STRING=""

if [[ "$reply" =~ ^[Yy] ]]; then
  USE_DOCKER=true
  echo

  # ---- collect credentials ------------------------------------------------

  echo "  Configuración del contenedor PostgreSQL (usuario admin):"
  echo -n "    Usuario admin (default: admin): "
  PG_ADMIN_USER="admin"
  if $INTERACTIVE; then read -r PG_ADMIN_USER; PG_ADMIN_USER="${PG_ADMIN_USER:-admin}"; fi

  echo -n "    Contraseña admin (default: admin): "
  PG_ADMIN_PASSWORD="admin"
  if $INTERACTIVE; then read -r PG_ADMIN_PASSWORD; PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-admin}"; fi
  echo

  echo "  Configuración del usuario de la aplicación PostgreSQL:"
  echo -n "    Usuario app (default: aiuser): "
  APP_USER="aiuser"
  if $INTERACTIVE; then read -r APP_USER; APP_USER="${APP_USER:-aiuser}"; fi

  echo -n "    Contraseña app (default: AI123456): "
  APP_PASSWORD="AI123456"
  if $INTERACTIVE; then read -r APP_PASSWORD; APP_PASSWORD="${APP_PASSWORD:-AI123456}"; fi

  # ---- backup files -------------------------------------------------------

  cp "$PROJECT_DIR/Docker/docker-compose.yml" "$PROJECT_DIR/Docker/docker-compose.yml.bak"
  cp "$PROJECT_DIR/Docker/init-user.sql" "$PROJECT_DIR/Docker/init-user.sql.bak"

  # ---- replace placeholders ------------------------------------------------

  sed -i \
    -e "s/__PG_ADMIN_USER__/$PG_ADMIN_USER/g" \
    -e "s/__PG_ADMIN_PASSWORD__/$PG_ADMIN_PASSWORD/g" \
    "$PROJECT_DIR/Docker/docker-compose.yml"

  sed -i \
    -e "s/__APP_USER__/$APP_USER/g" \
    -e "s/__APP_PASSWORD__/$APP_PASSWORD/g" \
    "$PROJECT_DIR/Docker/init-user.sql"

  # ---- start container ----------------------------------------------------

  echo -e "  \033[32m✓\033[0m Starting Docker container..."

  cd "$PROJECT_DIR/Docker"
  $DOCKER_COMPOSE_CMD up -d 2>/dev/null || {
    echo -e "  \033[31m✗\033[0m Failed to start Docker container."
    echo "    Check the error above and fix it, or run manually:"
    echo "    cd Docker && $DOCKER_COMPOSE_CMD up -d"
    exit 1
  }

  echo -n "    Waiting for PostgreSQL to be healthy"
  for i in {1..12}; do
    if docker ps --filter "name=postgres-vector" --filter "health=healthy" --format "{{.Names}}" 2>/dev/null | grep -q postgres-vector; then
      echo " ready!"
      break
    fi
    echo -n "."
    sleep 5
  done
  echo

  if ! docker ps --filter "name=postgres-vector" --filter "health=healthy" --format "{{.Names}}" 2>/dev/null | grep -q postgres-vector; then
    echo -e "  \033[31m✗\033[0m Container did not become healthy in 60s."
    echo "    Check with: cd Docker && $DOCKER_COMPOSE_CMD logs"
    exit 1
  fi

  # ---- restore files to placeholder state -----------------------------------

  mv "$PROJECT_DIR/Docker/docker-compose.yml.bak" "$PROJECT_DIR/Docker/docker-compose.yml"
  mv "$PROJECT_DIR/Docker/init-user.sql.bak" "$PROJECT_DIR/Docker/init-user.sql"

  # ---- connection string ---------------------------------------------------

  CONN_STRING="postgresql://$APP_USER:$APP_PASSWORD@127.0.0.1:5432/contexto"
  echo -e "  \033[32m✓\033[0m Connection string: $CONN_STRING"

  cd "$PROJECT_DIR"

  # Ensure psql is available for the Docker user
  ensure_bin "psql" "$PSQL_PKG" "psql (client)" || {
    echo "  psql client is needed to create the database table."
    exit 1
  }
else
  # Manual PostgreSQL: ensure psql is available
  ensure_bin "psql" "$PSQL_PKG" "psql (client)" || {
    echo "  psql client is needed. Install it and re-run."
    exit 1
  }

  CONN_STRING=$(json_get "$CONFIG_DEST" "['connectionString']" 2>/dev/null || echo "")
  if [[ -z "$CONN_STRING" ]]; then
    echo
    echo "  PostgreSQL connection string is required."
    echo '  Example: postgresql://user:password@host:5432/dbname'
    echo -n "  Enter connection string: "
    if $INTERACTIVE; then read -r CONN_STRING; else CONN_STRING="postgresql://user:password@host:5432/dbname"; fi
  else
    echo -e "  \033[32m✓\033[0m Existing connection string found in config"
  fi
fi

# pgvector check
echo
VEC_CHECK=$(psql "$CONN_STRING" -t -A \
  -c "SELECT installed_version FROM pg_available_extensions WHERE name='vector'" 2>/dev/null || echo "")

if [[ -n "$VEC_CHECK" ]]; then
  echo -e "  \033[32m✓\033[0m pgvector $VEC_CHECK detected in target database"
else
  echo -e "  \033[31m✗\033[0m pgvector extension not found in the target database."
  if $USE_DOCKER; then
    echo "    The init-user.sql script should have installed it."
    echo "    Check the container logs: cd Docker && $DOCKER_COMPOSE_CMD logs"
  else
    echo "    Install it as superuser:  CREATE EXTENSION IF NOT EXISTS vector;"
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# 3.  Install npm dependencies
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m3. Installing npm dependencies\033[0m"

cd "$OPENCODE_CONFIG_DIR"
if [[ ! -f package.json ]]; then
  npm init -y --silent 2>/dev/null || true
fi
npm install pg --no-audit --no-fund --loglevel=warn 2>/dev/null
echo -e "  \033[32m✓\033[0m pg installed in $OPENCODE_CONFIG_DIR/node_modules"

cd "$PROJECT_DIR"
npm install --no-audit --no-fund --loglevel=warn 2>/dev/null
echo -e "  \033[32m✓\033[0m dev dependencies installed in project"

# ---------------------------------------------------------------------------
# 4.  Copy plugin file
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m4. Copying plugin file\033[0m"

mkdir -p "$OPENCODE_CONFIG_DIR/plugins"
cp "$PROJECT_DIR/src/memory-pg.ts" "$PLUGIN_DEST"
echo -e "  \033[32m✓\033[0m Copied to $PLUGIN_DEST"

# ---------------------------------------------------------------------------
# 5.  Configuration
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m5. Configuration\033[0m"

if [[ -f "$CONFIG_DEST" ]]; then
  echo -e "  \033[33m⚠\033[0m Config already exists at $CONFIG_DEST"
  echo -n "    Overwrite? [y/N] "
  if $INTERACTIVE; then read -r reply; reply="${reply:-N}"; else reply="N"; fi
  if [[ "$reply" =~ ^[Yy] ]]; then
    cp "$PROJECT_DIR/config/memory-pg.json" "$CONFIG_DEST"
    echo -e "  \033[32m✓\033[0m Config overwritten"
  else
    echo "  Keeping existing config."
  fi
else
  cp "$PROJECT_DIR/config/memory-pg.json" "$CONFIG_DEST"
  echo -e "  \033[32m✓\033[0m Default config copied to $CONFIG_DEST"
fi

# Always update the connection string
json_set "$CONFIG_DEST" "['connectionString']='$CONN_STRING'"
echo -e "  \033[32m✓\033[0m Connection string updated in config"

# ---------------------------------------------------------------------------
# 6.  Create database table
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m6. Creating database table\033[0m"

DIMS=$(json_get "$CONFIG_DEST" ".get('embeddingDimensions',4096)")
if $USE_DOCKER; then
  echo "  Waiting for database to accept connections..."
  sleep 3
fi
psql "$CONN_STRING" -q -c "
  CREATE EXTENSION IF NOT EXISTS vector;
  CREATE TABLE IF NOT EXISTS memories (
    id           SERIAL PRIMARY KEY,
    content      TEXT NOT NULL,
    embedding    vector($DIMS),
    metadata     JSONB DEFAULT '{}',
    scope        TEXT NOT NULL DEFAULT 'user',
    project_hash TEXT,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at   TIMESTAMPTZ DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS idx_memories_scope
    ON memories (scope, project_hash);
" 2>/dev/null
echo -e "  \033[32m✓\033[0m Table 'memories' ready"

# ---------------------------------------------------------------------------
# 7.  Update opencode.jsonc
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m7. Registering plugin in opencode config\033[0m"

if [[ -f "$OPENCODE_MAIN_CONFIG" ]]; then
  cp "$OPENCODE_MAIN_CONFIG" "${OPENCODE_MAIN_CONFIG}.bak"
  echo -e "  \033[32m✓\033[0m Backup saved to ${OPENCODE_MAIN_CONFIG}.bak"
fi

if grep -q 'memory-pg' "$OPENCODE_MAIN_CONFIG" 2>/dev/null; then
  echo -e "  \033[33m⚠\033[0m Plugin already registered in opencode.jsonc"
else
  python3 -c "
import json, os
path = '$OPENCODE_MAIN_CONFIG'
entry = '$PLUGIN_DEST'

if os.path.exists(path):
    with open(path) as f:
        d = json.load(f)
else:
    d = {'\$schema': 'https://opencode.ai/config.json'}

existing = d.get('plugin', [])
if entry not in existing:
    existing.append(entry)
d['plugin'] = existing

with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
  echo -e "  \033[32m✓\033[0m Plugin registered in $OPENCODE_MAIN_CONFIG"
fi

# ---------------------------------------------------------------------------
# 8.  Verify embedding API
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m8. Verifying embedding API\033[0m"

API_KEY="${NAN_API_KEY:-}"
if [[ -z "$API_KEY" && -f "$OPENCODE_MAIN_CONFIG" ]]; then
  API_KEY=$(json_get "$OPENCODE_MAIN_CONFIG" ".get('provider',{}).get('litellm',{}).get('options',{}).get('apiKey','')")
fi

if [[ -z "$API_KEY" ]]; then
  echo -e "  \033[33m⚠\033[0m NAN_API_KEY not found."
  echo -n "    Enter your NaN API key (or leave empty to skip verification): "
  if $INTERACTIVE; then read -r API_KEY; else API_KEY=""; fi
fi

if [[ -n "$API_KEY" ]]; then
  BASE_URL=$(json_get "$CONFIG_DEST" ".get('embeddingBaseUrl','https://api.nan.builders/v1')")
  MODEL=$(json_get "$CONFIG_DEST" ".get('embeddingModel','qwen3-embedding')")
  RESP=$(curl -s "$BASE_URL/embeddings" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"input\":\"test\"}")
  DIMS_CHECK=$(echo "$RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'data' in d and 'embedding' in d['data'][0]:
    print(len(d['data'][0]['embedding']))
else:
    print('error')
" 2>/dev/null || echo "error")

  if [[ "$DIMS_CHECK" != "error" ]]; then
    echo -e "  \033[32m✓\033[0m Embedding API responds ($DIMS_CHECK dimensions)"
  else
    ERROR_MSG=$(echo "$RESP" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(d.get('error',{}).get('message','unknown'))
" 2>/dev/null || echo "unknown")
    echo -e "  \033[31m✗\033[0m Embedding API error: $ERROR_MSG"
    echo "    Check your API key and base URL in $CONFIG_DEST"
  fi
else
  echo -e "  \033[33m⚠\033[0m Embedding API verification skipped (no API key)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m━━━ Installation complete ─────────────────────────────────\033[0m"
echo
echo "  Plugin:  $PLUGIN_DEST"
echo "  Config:  $CONFIG_DEST"
echo "  Table:   memories (in database)"
if $USE_DOCKER; then
  echo "  Docker:  postgres-vector container running"
  echo "  To stop:  cd $PROJECT_DIR/Docker && $DOCKER_COMPOSE_CMD down"
fi
echo
echo -e "  \033[33m▶ Restart opencode for the changes to take effect.\033[0m"
echo
echo "  Next steps:"
echo "    - Run tests:     python3 test/test.py"
echo "    - Use in chat:   \"Recuerda que me gusta el castellano\""
echo "    - Uninstall:     bash uninstall.sh"
echo