#!/usr/bin/env bash
set -euo pipefail

events_path="${EVENTS_PATH:-$HOME/.config/opencode/agent-memory-systems-postgres/compaction-events.jsonl}"
out_dir="${OUT_DIR:-$HOME/.config/opencode/agent-memory-systems-postgres/compaction-daily}"

if [ ! -f "$events_path" ]; then
  events_path="$HOME/.claude/compaction-events.jsonl"
  out_dir="$HOME/.claude/compaction-daily"
fi

if [ ! -f "$events_path" ]; then
  exit 0
fi

mkdir -p "$out_dir"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

jq -r 'select((.event=="session.compacting" or .event=="PreCompact") and .time_utc) | .time_utc[0:10] as $d | [$d, (.session_id//"unknown"), (.trigger//"unknown")] | @tsv' "$events_path" \
  | awk -F"\t" '
    {
      day=$1; sess=$2; trig=$3;
      c[day]++;
      s[day]=s[day] (s[day]?", ":"") sess;
      t[day,trig]++;
      days[day]=1;
    }
    END {
      for (d in days) {
        triggers="";
        for (k in t) {
          split(k, parts, SUBSEP);
          if (parts[1]==d) {
            triggers=triggers (triggers?", ":"") parts[2] "=" t[k];
          }
        }
        printf "date_utc=%s\ncount=%d\ntriggers=%s\nsessions=%s\n", d, c[d], triggers, s[d];
      }
    }
  ' \
  | while IFS= read -r line; do
      case "$line" in
        date_utc=*)
          day="${line#date_utc=}"
          file="$out_dir/$day.txt"
          : > "$file"
          echo "$line" >> "$file"
          ;;
        *)
          echo "$line" >> "$file"
          ;;
      esac
    done

if command -v psql >/dev/null 2>&1; then
  for f in "$out_dir"/*.txt; do
    [ -f "$f" ] || continue
    day="$(basename "$f" .txt)"
    content_b64="$(base64 < "$f" | tr -d '\n')"
    psql -w -h localhost -p 5432 -U postgres -d agent_memory -v ON_ERROR_STOP=1 \
      -v "day=$day" \
      -v "content_b64=$content_b64" \
      -c "WITH payload AS (SELECT convert_from(decode(:'content_b64','base64'),'UTF8') AS content) SELECT store_memory('semantic','compaction-daily',ARRAY['compaction','daily'],'Compaction Daily Summary ' || :'day', (SELECT content FROM payload), jsonb_build_object('date_utc', :'day', 'source', 'consolidate-compactions.sh'), 'opencode-maintenance', NULL, 6.5);" \
      >/dev/null 2>&1 || true
  done
fi

exit 0
