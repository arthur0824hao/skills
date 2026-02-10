#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-ready}"
arg1="${2:-}"
arg2="${3:-}"
arg3="${4:-}"

pg_host="${PGHOST:-localhost}"
pg_port="${PGPORT:-5432}"
pg_db="${PGDATABASE:-agent_memory}"
pg_user="${PGUSER:-postgres}"

psql_cmd=(psql -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -t -A)

escape_sql_literal() {
  # escape single quotes for SQL literals
  printf "%s" "$1" | sed "s/'/''/g"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/tasks.sh ready [limit]
  scripts/tasks.sh create <title> [priority]
  scripts/tasks.sh block <blocker_id> <blocked_id>
  scripts/tasks.sh parent <parent_id> <child_id>
  scripts/tasks.sh claim <task_id> <assignee>
  scripts/tasks.sh link-mem <task_id> <memory_id> [link_type]
  scripts/tasks.sh rebuild
EOF
}

case "$cmd" in
  ready)
    limit="${arg1:-50}"
    "${psql_cmd[@]}" -c "SELECT id || E'\t' || priority || E'\t' || status || E'\t' || coalesce(assignee,'') || E'\t' || title FROM agent_tasks t WHERE t.deleted_at IS NULL AND t.status IN ('open','in_progress') AND NOT EXISTS (SELECT 1 FROM blocked_tasks_cache b WHERE b.task_id = t.id) ORDER BY priority ASC, updated_at ASC LIMIT $limit;"
    ;;
  create)
    [ -n "$arg1" ] || { usage; exit 2; }
    title=$(escape_sql_literal "$arg1")
    prio="${arg2:-2}"
    "${psql_cmd[@]}" -c "INSERT INTO agent_tasks(title, created_by, priority) VALUES ('$title','user',$prio) RETURNING id;"
    ;;
  block)
    [ -n "$arg1" ] && [ -n "$arg2" ] || { usage; exit 2; }
    "${psql_cmd[@]}" -c "INSERT INTO task_links(from_task_id,to_task_id,link_type) VALUES ($arg1,$arg2,'blocks') ON CONFLICT DO NOTHING;"
    ;;
  parent)
    [ -n "$arg1" ] && [ -n "$arg2" ] || { usage; exit 2; }
    "${psql_cmd[@]}" -c "INSERT INTO task_links(from_task_id,to_task_id,link_type) VALUES ($arg1,$arg2,'parent_child') ON CONFLICT DO NOTHING;"
    ;;
  claim)
    [ -n "$arg1" ] && [ -n "$arg2" ] || { usage; exit 2; }
    assignee=$(escape_sql_literal "$arg2")
    "${psql_cmd[@]}" -c "SELECT claim_task($arg1, '$assignee');"
    ;;
  link-mem)
    [ -n "$arg1" ] && [ -n "$arg2" ] || { usage; exit 2; }
    lt="${arg3:-supports}"
    lt=$(escape_sql_literal "$lt")
    "${psql_cmd[@]}" -c "INSERT INTO task_memory_links(task_id,memory_id,link_type) VALUES ($arg1,$arg2,'$lt') ON CONFLICT DO NOTHING;"
    ;;
  rebuild)
    "${psql_cmd[@]}" -c "SELECT rebuild_blocked_tasks_cache();"
    ;;
  *)
    usage
    exit 2
    ;;
esac
