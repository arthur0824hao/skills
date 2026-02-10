#!/usr/bin/env bash
set -euo pipefail

ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

read_stdin_json() {
  if command -v jq >/dev/null 2>&1; then
    cat
  else
    cat >/dev/null
    echo "{}"
  fi
}

input_json="$(read_stdin_json)"

session_id="$(echo "$input_json" | jq -r '.session_id // .sessionID // "unknown"' 2>/dev/null || echo unknown)"
trigger="$(echo "$input_json" | jq -r '.trigger // "unknown"' 2>/dev/null || echo unknown)"
cwd="$(echo "$input_json" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
transcript_path="$(echo "$input_json" | jq -r '.transcript_path // .transcriptPath // ""' 2>/dev/null || echo "")"
timestamp="$(ts_utc)"

log_path="$HOME/.claude/compaction-events.jsonl"
mkdir -p "$(dirname "$log_path")"

tail_b64=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  tail_b64="$(tail -c 8192 "$transcript_path" | base64 | tr -d '\n')"
fi

printf '{"event":"PreCompact","time_utc":"%s","session_id":"%s","trigger":"%s","cwd":"%s","transcript_path":"%s","transcript_tail_b64":"%s"}\n' \
  "$timestamp" "$session_id" "$trigger" "$cwd" "$transcript_path" "$tail_b64" >> "$log_path" || true

if ! command -v psql >/dev/null 2>&1; then
  exit 0
fi

sql=$'WITH t AS (\n'
sql+=$'  SELECT CASE WHEN length(:\x27tail_b64\x27) > 0\n'
sql+=$'       THEN convert_from(decode(:\x27tail_b64\x27, \x27base64\x27), \x27UTF8\x27)\n'
sql+=$'       ELSE \x27\x27 END AS tail\n'
sql+=$')\n'
sql+=$'SELECT store_memory(\n'
sql+=$'  \x27episodic\x27,\n'
sql+=$'  \x27compaction\x27,\n'
sql+=$'  ARRAY[\x27compaction\x27, :\x27trigger\x27],\n'
sql+=$'  \x27Compaction \x27 || :\x27session_id\x27 || \x27 \x27 || :\x27timestamp\x27,\n'
sql+=$'  \x27trigger=\x27 || :\x27trigger\x27 || E\x27\\n\x27\n'
sql+=$'    || \x27cwd=\x27 || :\x27cwd\x27 || E\x27\\n\x27\n'
sql+=$'    || \x27transcript_path=\x27 || :\x27transcript_path\x27 || E\x27\\n\\n\x27\n'
sql+=$'    || (SELECT tail FROM t),\n'
sql+=$'  jsonb_build_object(\n'
sql+=$'    \x27session_id\x27, :\x27session_id\x27,\n'
sql+=$'    \x27trigger\x27, :\x27trigger\x27,\n'
sql+=$'    \x27timestamp_utc\x27, :\x27timestamp\x27,\n'
sql+=$'    \x27cwd\x27, :\x27cwd\x27,\n'
sql+=$'    \x27transcript_path\x27, :\x27transcript_path\x27,\n'
sql+=$'    \x27source\x27, \x27claude-hook-precompact\x27\n'
sql+=$'  ),\n'
sql+=$'  \x27claude-hook\x27,\n'
sql+=$'  :\x27session_id\x27,\n'
sql+=$'  7.0\n'
sql+=$');'

psql -w -h localhost -p 5432 -U postgres -d agent_memory \
  -v ON_ERROR_STOP=1 \
  -v "session_id=$session_id" \
  -v "trigger=$trigger" \
  -v "timestamp=$timestamp" \
  -v "cwd=$cwd" \
  -v "transcript_path=$transcript_path" \
  -v "tail_b64=$tail_b64" \
  -c "$sql" >/dev/null 2>&1 || true

exit 0
