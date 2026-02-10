#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-types}"

pg_host="${PGHOST:-localhost}"
pg_port="${PGPORT:-5432}"
pg_db="${PGDATABASE:-agent_memory}"
pg_user="${PGUSER:-postgres}"

psql_cmd=(psql -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -t -A)

fail() {
  local msg="$1"
  printf '%s\n' "{\"status\":\"error\",\"summary\":\"$msg\",\"errors\":[{\"code\":\"MEM_ROUTER_ADAPTER\",\"message\":\"$msg\"}],\"artifacts\":[],\"metrics\":{}}"
  exit 1
}

sql_json() {
  local sql="$1"
  "${psql_cmd[@]}" -c "$sql" | tr -d '\r'
}

usage() {
  cat <<'EOF'
Usage:
  scripts/router_mem.sh types
  scripts/router_mem.sh health
  scripts/router_mem.sh search <query> [limit]
  scripts/router_mem.sh store <memory_type> <category> <title> [tags_csv] [importance]

Notes:
  - For store: content is read from STDIN.
  - Emits a single JSON object on stdout (for Router last-line JSON contract).
EOF
}

case "$cmd" in
  types)
    sql_json "SELECT jsonb_build_object('status','ok','summary','types','results',COALESCE((SELECT jsonb_agg(x) FROM (SELECT unnest(enum_range(NULL::memory_type)) AS x) t),'[]'::jsonb))::text;" || fail "types query failed"
    ;;

  health)
    sql_json "SELECT jsonb_build_object('status','ok','summary','health','results',COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM memory_health_check() t),'[]'::jsonb))::text;" || fail "health query failed"
    ;;

  search)
    q="${2:-}"
    limit="${3:-10}"
    [ -n "$q" ] || { usage; exit 2; }
    "${psql_cmd[@]}" -v "q=$q" -v "limit=$limit" -c "SELECT jsonb_build_object('status','ok','summary','search','results',COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM (SELECT id, memory_type, category, title, relevance_score, match_type FROM search_memories(:'q', NULL, NULL, NULL, NULL, 0.0, :limit) ORDER BY relevance_score DESC) r),'[]'::jsonb))::text;" | tr -d '\r' || fail "search failed"
    ;;

  store)
    mtype="${2:-}"
    category="${3:-}"
    title="${4:-}"
    tags_csv="${5:-}"
    importance="${6:-5}"
    [ -n "$mtype" ] && [ -n "$category" ] && [ -n "$title" ] || { usage; exit 2; }
    if [ -t 0 ]; then
      fail "No content on stdin"
    fi
    content=$(cat)
    if [ -z "$content" ]; then
      fail "Empty content on stdin"
    fi
    stored_id=$(printf '%s' "$content" | bash "$(dirname "$0")/mem.sh" store "$mtype" "$category" "$title" "$tags_csv" "$importance" 2>/dev/null | tr -d '\r' | tail -n 1 || true)
    [ -n "$stored_id" ] || fail "store failed"
    printf '%s\n' "{\"status\":\"ok\",\"summary\":\"store\",\"results\":[{\"stored_id\":$stored_id}],\"artifacts\":[],\"metrics\":{},\"errors\":[]}" 
    ;;

  *)
    usage
    exit 2
    ;;
esac
