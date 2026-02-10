#!/usr/bin/env bash
set -euo pipefail

install_all="${1:-}"

if [ "$install_all" != "--install-all" ] && [ ! -t 0 ]; then
  echo "Non-interactive stdin detected. Re-run interactively, or pass --install-all." >&2
  exit 1
fi

yesno() {
  local prompt="$1"
  local def="$2" # y or n
  local ans=""
  if [ "$def" = "y" ]; then
    read -r -p "$prompt [Y/n] " ans || true
    ans="${ans:-y}"
  else
    read -r -p "$prompt [y/N] " ans || true
    ans="${ans:-n}"
  fi
  case "${ans,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

selected_pgpass="false"
selected_ollama="false"
selected_pgvector="false"
selected_opencode_plugin="false"

if [ "$install_all" = "--install-all" ]; then
  selected_pgpass="true"
  selected_ollama="true"
  selected_pgvector="true"
  selected_opencode_plugin="true"
else
  if yesno "Set up .pgpass for non-interactive psql?" y; then selected_pgpass="true"; fi
  if yesno "Install/use Ollama for local embeddings?" n; then selected_ollama="true"; fi
  if yesno "Enable pgvector extension (vector)?" n; then selected_pgvector="true"; fi
  if yesno "Install OpenCode plugin for compaction logging?" n; then selected_opencode_plugin="true"; fi
fi

setup_file="$HOME/.config/opencode/skill-system-memory/setup.json"
mkdir -p "$(dirname "$setup_file")"

cat > "$setup_file" <<EOF
{"time_utc":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","os":"unix","selected":{"pgpass":$selected_pgpass,"ollama":$selected_ollama,"pgvector":$selected_pgvector,"opencode_plugin":$selected_opencode_plugin}}
EOF

echo "Wrote setup record to $setup_file"
echo "Bootstrap complete."

if [ "$selected_pgpass" = "true" ]; then
  if [ -f "$(dirname "$0")/setup-pgpass.sh" ]; then
    bash "$(dirname "$0")/setup-pgpass.sh" || true
  fi
fi

if [ "$selected_pgvector" = "true" ] && command -v psql >/dev/null 2>&1; then
  psql -w -h localhost -p 5432 -U postgres -d agent_memory -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true
fi

if [ "$selected_opencode_plugin" = "true" ]; then
  src_dir="$(cd "$(dirname "$0")/.." && pwd)"
  src="$src_dir/plugins/skill-system-memory.js"
  dst_dir="$HOME/.config/opencode/plugins"
  mkdir -p "$dst_dir"
  if [ -f "$src" ]; then
    cp -f "$src" "$dst_dir/skill-system-memory.js"
    echo "Installed OpenCode plugin to $dst_dir/skill-system-memory.js"
    echo "Restart OpenCode to load plugin"
  else
    echo "Plugin source not found: $src" >&2
  fi
fi

exit 0
