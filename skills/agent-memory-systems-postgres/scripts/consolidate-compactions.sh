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

generate_daily_files_jq() {
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
}

generate_daily_files_python() {
  python - <<'PY'
import json
import os
from collections import defaultdict, Counter

events_path = os.environ["EVENTS_PATH"]
out_dir = os.environ["OUT_DIR"]

counts = defaultdict(int)
sessions = defaultdict(list)
triggers = defaultdict(Counter)

with open(events_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ev = obj.get("event")
        t = obj.get("time_utc")
        if ev not in ("session.compacting", "PreCompact") or not t:
            continue
        day = str(t)[:10]
        sid = str(obj.get("session_id") or "unknown")
        trig = str(obj.get("trigger") or "unknown")
        counts[day] += 1
        sessions[day].append(sid)
        triggers[day][trig] += 1

for day in sorted(counts.keys()):
    path = os.path.join(out_dir, f"{day}.txt")
    uniq_sessions = []
    seen = set()
    for sid in sessions[day]:
        if sid in seen:
            continue
        seen.add(sid)
        uniq_sessions.append(sid)
    trig_parts = [f"{k}={v}" for k, v in sorted(triggers[day].items())]
    with open(path, "w", encoding="utf-8") as out:
        out.write(f"date_utc={day}\n")
        out.write(f"count={counts[day]}\n")
        out.write(f"triggers={', '.join(trig_parts)}\n")
        out.write(f"sessions={', '.join(uniq_sessions)}\n")
PY
}

if command -v jq >/dev/null 2>&1; then
  generate_daily_files_jq
else
  export EVENTS_PATH="$events_path"
  export OUT_DIR="$out_dir"
  generate_daily_files_python
fi

if command -v psql >/dev/null 2>&1; then
  pg_host="${PGHOST:-localhost}"
  pg_port="${PGPORT:-5432}"
  pg_db="${PGDATABASE:-agent_memory}"
  pg_user="${PGUSER:-$(whoami)}"
  for f in "$out_dir"/*.txt; do
    [ -f "$f" ] || continue
    day="$(basename "$f" .txt)"
    content_b64="$(base64 < "$f" | tr -d '\n')"
    psql -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 \
      -v "day=$day" \
      -v "content_b64=$content_b64" \
      -c "WITH payload AS (SELECT convert_from(decode(:'content_b64','base64'),'UTF8') AS content) SELECT store_memory('semantic','compaction-daily',ARRAY['compaction','daily'],'Compaction Daily Summary ' || :'day', (SELECT content FROM payload), jsonb_build_object('date_utc', :'day', 'source', 'consolidate-compactions.sh'), 'opencode-maintenance', NULL, 6.5);" \
      >/dev/null 2>&1 || true
  done
fi

exit 0
