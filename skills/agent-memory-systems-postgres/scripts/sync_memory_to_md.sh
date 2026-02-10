#!/usr/bin/env bash
set -euo pipefail

no_backup="false"
out_dir=""
limit_long="200"
limit_short="50"
limit_episodic="200"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-backup) no_backup="true"; shift ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --limit-long) limit_long="$2"; shift 2 ;;
    --limit-short) limit_short="$2"; shift 2 ;;
    --limit-episodic) limit_episodic="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  scripts/sync_memory_to_md.sh [--out-dir DIR] [--no-backup] [--limit-long N] [--limit-short N] [--limit-episodic N]

Outputs (in Memory/):
  - Long.md     (semantic + procedural)
  - Short.md    (friction + compaction-daily + skill-test + skill-publish)
  - Episodic.md (episodic)

Backups:
  - default: Memory/.backups/<file>.<timestamp>.bak
  - disable: --no-backup
EOF
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

pg_host="${PGHOST:-localhost}"
pg_port="${PGPORT:-5432}"
pg_db="${PGDATABASE:-agent_memory}"
pg_user="${PGUSER:-postgres}"

psql_cmd=(psql -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -X -q -t -A)

psql_bin="psql"
if command -v psql >/dev/null 2>&1; then
  psql_bin="psql"
elif command -v psql.exe >/dev/null 2>&1; then
  psql_bin="psql.exe"
elif [ -x "/c/Program Files/PostgreSQL/18/bin/psql.exe" ]; then
  psql_bin="/c/Program Files/PostgreSQL/18/bin/psql.exe"
elif [ -x "/c/Program Files/PostgreSQL/17/bin/psql.exe" ]; then
  psql_bin="/c/Program Files/PostgreSQL/17/bin/psql.exe"
elif [ -x "/c/Program Files/PostgreSQL/16/bin/psql.exe" ]; then
  psql_bin="/c/Program Files/PostgreSQL/16/bin/psql.exe"
elif [ -x "/c/Program Files/PostgreSQL/15/bin/psql.exe" ]; then
  psql_bin="/c/Program Files/PostgreSQL/15/bin/psql.exe"
elif [ -x "/c/Program Files/PostgreSQL/14/bin/psql.exe" ]; then
  psql_bin="/c/Program Files/PostgreSQL/14/bin/psql.exe"
else
  echo "psql not found. Install PostgreSQL client or set PATH/PSQL." >&2
  exit 1
fi

psql_cmd=("$psql_bin" -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -X -q -t -A)

if [ -z "$out_dir" ]; then
  out_dir="${MEMORY_MD_DIR:-$PWD/Memory}"
fi

mem_dir="$out_dir"
backup_dir="$mem_dir/.backups"
status_file="$mem_dir/SYNC_STATUS.txt"

mkdir -p "$mem_dir"
mkdir -p "$backup_dir"

if [ ! -f "$mem_dir/.gitignore" ]; then
  cat > "$mem_dir/.gitignore" <<'EOF'
.backups/
SYNC_STATUS.txt
EOF
fi

ts_utc="$(date -u +"%Y-%m-%dT%H%M%SZ")"

backup_file() {
  local path="$1"
  if [ "$no_backup" = "true" ]; then
    return 0
  fi
  if [ -f "$path" ]; then
    local base
    base="$(basename "$path")"
    cp -f "$path" "$backup_dir/$base.$ts_utc.bak"
  fi
}

write_md() {
  local out="$1"
  local sql="$2"
  backup_file "$out"
  "${psql_cmd[@]}" -c "$sql" > "$out" 2>/dev/null
}

common_fmt="
  '## ' || m.id::text || ' - ' || m.title || E'\\n'
  || '- type: ' || m.memory_type::text || E'\\n'
  || '- category: ' || m.category || E'\\n'
  || '- importance: ' || m.importance_score::text || E'\\n'
  || '- accessed_at_utc: ' || (
      to_char(m.accessed_at at time zone 'utc', 'YYYY-MM-DD')
      || 'T'
      || to_char(m.accessed_at at time zone 'utc', 'HH24:MI:SS')
      || 'Z'
    ) || E'\\n'
  || '- tags: ' || COALESCE(array_to_string(m.tags, ', '), '') || E'\\n'
  || E'\\n'
  || '~~~~' || E'\\n'
  || COALESCE(m.content, '') || E'\\n'
  || '~~~~' || E'\\n'"

header_expr="
  '# Agent Memory Export' || E'\\n'
  || 'time_utc: ' || (
      to_char(now() at time zone 'utc', 'YYYY-MM-DD')
      || 'T'
      || to_char(now() at time zone 'utc', 'HH24:MI:SS')
      || 'Z'
    ) || E'\\n'
  || 'db: ' || current_database() || E'\\n'
  || E'\\n'"

long_sql="WITH rows AS (
  SELECT m.*
  FROM agent_memories m
  WHERE m.deleted_at IS NULL
    AND m.memory_type IN ('semantic','procedural')
  ORDER BY m.importance_score DESC, m.accessed_at DESC
  LIMIT $limit_long
)
SELECT
  (${header_expr})
  || '# Long' || E'\\n'
  || COALESCE(string_agg((${common_fmt}), E'\\n'), '')
FROM rows m;"

short_sql="WITH rows AS (
  SELECT m.*
  FROM agent_memories m
  WHERE m.deleted_at IS NULL
    AND (
      m.category IN ('friction','compaction-daily','skill-test','skill-publish')
      OR (m.memory_type = 'procedural' AND m.importance_score >= 7.0)
    )
  ORDER BY m.accessed_at DESC
  LIMIT $limit_short
)
SELECT
  (${header_expr})
  || '# Short' || E'\\n'
  || COALESCE(string_agg((${common_fmt}), E'\\n'), '')
FROM rows m;"

episodic_sql="WITH rows AS (
  SELECT m.*
  FROM agent_memories m
  WHERE m.deleted_at IS NULL
    AND m.memory_type = 'episodic'
  ORDER BY m.accessed_at DESC
  LIMIT $limit_episodic
)
SELECT
  (${header_expr})
  || '# Episodic' || E'\\n'
  || COALESCE(string_agg((${common_fmt}), E'\\n'), '')
FROM rows m;"

write_md "$mem_dir/Long.md" "$long_sql"
write_md "$mem_dir/Short.md" "$short_sql"
write_md "$mem_dir/Episodic.md" "$episodic_sql"

{
  echo "time_utc=$ts_utc"
  echo "host=$pg_host"
  echo "port=$pg_port"
  echo "db=$pg_db"
  echo "long_limit=$limit_long"
  echo "short_limit=$limit_short"
  echo "episodic_limit=$limit_episodic"
} > "$status_file"

echo "Wrote: $mem_dir/Long.md"
echo "Wrote: $mem_dir/Short.md"
echo "Wrote: $mem_dir/Episodic.md"
echo "Status: $status_file"
