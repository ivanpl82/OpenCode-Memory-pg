#!/usr/bin/env bash
#
# uninstall.sh – Remove the memory-pg plugin from opencode.
#
# What it does:
#   1. Removes ~/.config/opencode/plugins/memory-pg.ts
#   2. Removes ~/.config/opencode/memory-pg.json
#   3. Removes the "plugin" entry from opencode.jsonc
#   4. Optionally drops the memories table from PostgreSQL
#
# Usage:
#   bash uninstall.sh
#
# ---------------------------------------------------------------------------

set -euo pipefail

OPENCODE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_FILE="$OPENCODE_CONFIG_DIR/plugins/memory-pg.ts"
CONFIG_FILE="$OPENCODE_CONFIG_DIR/memory-pg.json"
MAIN_CONFIG="$OPENCODE_CONFIG_DIR/opencode.jsonc"

echo -e "\033[1m━━━ memory-pg plugin uninstaller ━━━\033[0m"
echo

# ---------------------------------------------------------------------------
# JSON helper (python3)
# ---------------------------------------------------------------------------

json_get() {
  python3 -c "import json,sys; d=json.load(open('$1')); print(d$2)" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# 1.  Remove plugin file
# ---------------------------------------------------------------------------

if [[ -f "$PLUGIN_FILE" ]]; then
  rm "$PLUGIN_FILE"
  echo -e "  \033[32m✓\033[0m Removed $PLUGIN_FILE"
else
  echo -e "  \033[33m-\033[0m Plugin file not found (already removed?)"
fi

PLUGINS_DIR="$OPENCODE_CONFIG_DIR/plugins"
if [[ -d "$PLUGINS_DIR" && -z "$(ls -A "$PLUGINS_DIR")" ]]; then
  rmdir "$PLUGINS_DIR"
  echo -e "  \033[32m✓\033[0m Removed empty $PLUGINS_DIR"
fi

# ---------------------------------------------------------------------------
# 2.  Remove config file
# ---------------------------------------------------------------------------

if [[ -f "$CONFIG_FILE" ]]; then
  rm "$CONFIG_FILE"
  echo -e "  \033[32m✓\033[0m Removed $CONFIG_FILE"
else
  echo -e "  \033[33m-\033[0m Config file not found (already removed?)"
fi

# ---------------------------------------------------------------------------
# 3.  Update opencode.jsonc
# ---------------------------------------------------------------------------

if [[ -f "$MAIN_CONFIG" ]]; then
  cp "$MAIN_CONFIG" "${MAIN_CONFIG}.uninstall-bak"
  echo -e "  \033[32m✓\033[0m Backup saved to ${MAIN_CONFIG}.uninstall-bak"

  python3 -c "
import json

path = '$MAIN_CONFIG'
entry = '$PLUGIN_FILE'

with open(path) as f:
    d = json.load(f)

plug = d.get('plugin', [])
if entry in plug:
    plug.remove(entry)

if plug:
    d['plugin'] = plug
else:
    d.pop('plugin', None)

with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
  echo -e "  \033[32m✓\033[0m memory-pg entry removed from $MAIN_CONFIG"
fi

# ---------------------------------------------------------------------------
# 4.  Optionally drop database table
# ---------------------------------------------------------------------------

if [[ -f "$CONFIG_FILE" ]]; then
  echo
  echo "  Do you want to drop the 'memories' table from PostgreSQL?"
  echo "  This will PERMANENTLY delete all stored memories. [y/N] "
  read -r reply
  if [[ "${reply:-N}" =~ ^[Yy] ]]; then
    CONN_STRING=$(json_get "$CONFIG_FILE" "['connectionString']")
    if [[ -n "$CONN_STRING" ]]; then
      psql "$CONN_STRING" -q -c "DROP TABLE IF EXISTS memories;" 2>/dev/null \
        && echo -e "  \033[32m✓\033[0m Table 'memories' dropped" \
        || echo -e "  \033[31m✗\033[0m Failed to drop table (check connection string)"
    else
      echo -e "  \033[33m-\033[0m Cannot read connection string from config"
    fi
  else
    echo -e "  \033[33m-\033[0m Table 'memories' kept in database"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
echo -e "\033[1m━━━ Uninstall complete ─────────────────────────────────────\033[0m"
echo
echo -e "  \033[33m▶ Restart opencode for the changes to take effect.\033[0m"
echo