#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-types}"

pg_host="${PGHOST:-localhost}"
pg_port="${PGPORT:-5432}"
pg_db="${PGDATABASE:-agent_memory}"
pg_user="${PGUSER:-postgres}"

psql_cmd=(psql -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -t -A)

usage() {
  cat <<'EOF'
Usage:
  scripts/mem.sh types
  scripts/mem.sh health
  scripts/mem.sh search <query> [limit]
  scripts/mem.sh store <memory_type> <category> <title> [tags_csv] [importance]

Notes:
  - Prefer single quotes in shells that treat backticks specially (zsh).
  - For store: content is read from STDIN.
    Example: echo "content" | scripts/mem.sh store semantic project "Title" "tag1,tag2" 8
EOF
}

case "$cmd" in
  types)
    "${psql_cmd[@]}" -c "SELECT unnest(enum_range(NULL::memory_type))" ;;

  health)
    "${psql_cmd[@]}" -c "SELECT * FROM memory_health_check();" ;;

  search)
    q="${2:-}"
    limit="${3:-10}"
    [ -n "$q" ] || { usage; exit 2; }
    # psql -v substitution is safe for plain text here.
    "${psql_cmd[@]}" -v "q=$q" -v "limit=$limit" -c "SELECT id, memory_type, category, title, relevance_score, match_type FROM search_memories(:'q', NULL, NULL, NULL, NULL, 0.0, :limit) ORDER BY relevance_score DESC;" ;;

  store)
    mtype="${2:-}"
    category="${3:-}"
    title="${4:-}"
    tags_csv="${5:-}"
    importance="${6:-5}"
    [ -n "$mtype" ] && [ -n "$category" ] && [ -n "$title" ] || { usage; exit 2; }
    content=""
    # read all stdin (may be empty)
    if [ ! -t 0 ]; then
      content=$(cat)
    fi
    if [ -z "$content" ]; then
      echo "No content on stdin; abort." >&2
      exit 2
    fi
    "${psql_cmd[@]}" \
      -v "mtype=$mtype" \
      -v "category=$category" \
      -v "title=$title" \
      -v "tags=$tags_csv" \
      -v "importance=$importance" \
      -v "content=$content" \
      -c "SELECT store_memory(:'mtype'::memory_type, :'category', CASE WHEN length(:'tags')=0 THEN ARRAY[]::text[] ELSE string_to_array(:'tags', ',') END, :'title', :'content', '{}'::jsonb, 'user', NULL, :'importance'::numeric);" ;;

  *)
    usage
    exit 2
    ;;
esac
