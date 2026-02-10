#!/usr/bin/env bash
set -euo pipefail

LIMIT="${LIMIT:-25}"
MAX_CHARS="${MAX_CHARS:-8000}"
DRY_RUN="${DRY_RUN:-0}"

PROVIDER="${EMBEDDING_PROVIDER:-openai}"
API_URL="${EMBEDDING_API_URL:-}"
if [ -z "$API_URL" ]; then
  if [ "$PROVIDER" = "ollama" ]; then
    API_URL="http://localhost:11434/v1/embeddings"
  else
    API_URL="https://api.openai.com/v1/embeddings"
  fi
fi

MODEL="${EMBEDDING_MODEL:-}"
if [ -z "$MODEL" ]; then
  if [ "$PROVIDER" = "ollama" ]; then
    MODEL="nomic-embed-text"
  else
    MODEL="text-embedding-3-small"
  fi
fi

# If a setup record exists and ollama was selected, default to it.
setup_json="$HOME/.config/opencode/skill-system-memory/setup.json"
if [ -z "${EMBEDDING_PROVIDER:-}" ] && [ -f "$setup_json" ]; then
  sel_ollama="$(jq -r '.selected.ollama // false' "$setup_json" 2>/dev/null || echo false)"
  if [ "$sel_ollama" = "true" ]; then
    PROVIDER="ollama"
    if [ -z "${EMBEDDING_MODEL:-}" ]; then
      m="$(jq -r '.selected.ollama_model // empty' "$setup_json" 2>/dev/null || true)"
      if [ -n "$m" ]; then MODEL="$m"; fi
    fi
  fi
fi

DIMENSIONS="${EMBEDDING_DIMENSIONS:-}"

if [ -z "${EMBEDDING_API_KEY:-}" ]; then
  if [ "${EMBEDDING_PROVIDER:-openai}" = "ollama" ]; then
    # Required by OpenAI-compatible clients, ignored by Ollama
    EMBEDDING_API_KEY="ollama"
    export EMBEDDING_API_KEY
  else
    echo "No embeddings ingested (set EMBEDDING_API_KEY to enable)." >&2
    exit 0
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required" >&2
  exit 0
fi

HAS_EMB="$(psql -w -t -A -v ON_ERROR_STOP=1 -c "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='agent_memories' AND column_name='embedding');")"
if [ "$HAS_EMB" != "t" ]; then
  echo "agent_memories.embedding is missing. Install pgvector and re-run init.sql." >&2
  exit 0
fi

rows="$(psql -w -t -A -v ON_ERROR_STOP=1 -c "SELECT id || E'\t' || replace(title, E'\t', ' ') || E'\t' || replace(left(content, 20000), E'\t', ' ') FROM agent_memories WHERE deleted_at IS NULL AND embedding IS NULL ORDER BY importance_score DESC, accessed_at DESC LIMIT ${LIMIT};")"

if [ -z "$rows" ]; then
  echo "No rows need embeddings." >&2
  exit 0
fi

while IFS=$'\t' read -r id title content; do
  [ -n "$id" ] || continue
  input="$title\n\n$content"
  input="${input:0:${MAX_CHARS}}"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would embed id=$id" >&2
    continue
  fi

  req="$(jq -c --arg m "$MODEL" --arg i "$input" '{model:$m,input:$i}')"
  if [ -n "$DIMENSIONS" ]; then
    req="$(echo "$req" | jq -c --argjson d "$DIMENSIONS" '. + {dimensions:$d}')"
  fi

  resp="$(curl -sS \
    -H "Authorization: Bearer $EMBEDDING_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$req" \
    "$API_URL" || true)"

  emb="$(echo "$resp" | jq -c '.data[0].embedding // empty' 2>/dev/null || true)"
  if [ -z "$emb" ]; then
    echo "embed failed id=$id" >&2
    continue
  fi

  dim="$(echo "$emb" | jq 'length' 2>/dev/null || echo 0)"

  vec="[$(echo "$emb" | jq -r 'map(tostring) | join(",")') ]"

  psql -w -v ON_ERROR_STOP=1 \
    -v "id=$id" \
    -v "model=$MODEL" \
    -v "dim=$dim" \
    -v "api_url=$API_URL" \
    -v "provider=$PROVIDER" \
    -v "emb=$vec" \
    -c "UPDATE agent_memories SET embedding = :'emb'::vector, metadata = COALESCE(metadata,'{}'::jsonb) || jsonb_build_object('embedding_model', :'model', 'embedding_dim', :'dim', 'embedding_api_url', :'api_url', 'embedding_provider', :'provider', 'embedded_at', now()), updated_at = NOW() WHERE id = :'id'::bigint;" \
    >/dev/null 2>&1 || true

  echo "embedded id=$id dim=$dim" >&2
done <<< "$rows"

exit 0
