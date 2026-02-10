#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
task_id="${2:-}"

pg_host="${PGHOST:-localhost}"
pg_port="${PGPORT:-5432}"
pg_db="${PGDATABASE:-agent_memory}"
pg_user="${PGUSER:-postgres}"

psql_cmd=(psql -w -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -t -A)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_root="$(cd "$script_dir/../.." && pwd)"

json_tool=""
if command -v node >/dev/null 2>&1; then
  json_tool="node"
elif command -v python3 >/dev/null 2>&1; then
  json_tool="python3"
elif command -v python >/dev/null 2>&1; then
  json_tool="python"
fi

fail_json() {
  local msg="$1"
  printf '%s\n' "{\"status\":\"error\",\"summary\":\"$msg\",\"errors\":[{\"code\":\"ROUTER_ERROR\",\"message\":\"$msg\"}],\"artifacts\":[],\"metrics\":{}}"
  exit 1
}

require_json_tool() {
  if [ -z "$json_tool" ]; then
    fail_json "Missing JSON tool (need node or python)"
  fi
}

sql_one_json() {
  local sql="$1"
  "${psql_cmd[@]}" -c "$sql" | tr -d '\r'
}

get_task_spec_json() {
  local id="$1"
  sql_one_json "SELECT row_to_json(t)::text FROM (SELECT id, goal, workspace, inputs, verification, pinned_pipeline, budgets, policy_profile_id FROM skill_system.task_specs WHERE id = $id) t;"
}

get_policy_profile_json() {
  local id="$1"
  sql_one_json "SELECT row_to_json(t)::text FROM (SELECT id, name, allowed_effects, allowed_exec, allowed_write_roots, metadata FROM skill_system.policy_profiles WHERE id = $id) t;"
}

extract_manifest_block() {
  # prints block content to stdout
  local skill="$1"
  local skill_dir="$skills_root/$skill"
  local md="$skill_dir/SKILL.md"
  [ -f "$md" ] || fail_json "Skill SKILL.md not found: $md"
  awk '
    BEGIN{inblock=0}
    /^```router-manifest[[:space:]]*$/ {inblock=1; next}
    inblock && /^```[[:space:]]*$/ {exit}
    inblock {print}
  ' "$md"
}

manifest_get_effects() {
  local manifest_json="$1"
  require_json_tool
  if [ "$json_tool" = "node" ]; then
    node -e 'const fs=require("fs"); const m=JSON.parse(fs.readFileSync(0,"utf8")); (m.effects||[]).forEach(x=>process.stdout.write(String(x)+"\n"));' <<<"$manifest_json"
  else
    "$json_tool" -c 'import json,sys; m=json.load(sys.stdin); [print(x) for x in (m.get("effects") or [])]' <<<"$manifest_json"
  fi
}

manifest_get_entrypoint_argv() {
  local manifest_json="$1"
  local op="$2"
  local os_key="$3" # unix|windows
  require_json_tool
  if [ "$json_tool" = "node" ]; then
    node -e 'const fs=require("fs"); const [op,os]=process.argv.slice(1); const m=JSON.parse(fs.readFileSync(0,"utf8")); const ep=(((m.entrypoints||{})[op]||{})[os])||null; if(!ep){process.exit(2);} ep.forEach(x=>process.stdout.write(String(x)+"\n"));' "$op" "$os_key" <<<"$manifest_json"
  else
    "$json_tool" -c 'import json,sys; op=sys.argv[1]; os=sys.argv[2]; m=json.load(sys.stdin); ep=((m.get("entrypoints") or {}).get(op) or {}).get(os); 
if not ep: sys.exit(2)
print("\n".join([str(x) for x in ep]))' "$op" "$os_key" <<<"$manifest_json"
  fi
}

json_get() {
  local json="$1"
  local expr="$2"
  require_json_tool
  if [ "$json_tool" = "node" ]; then
    node -e 'const fs=require("fs"); const expr=process.argv[1]; const obj=JSON.parse(fs.readFileSync(0,"utf8")); const parts=expr.split("."); let cur=obj; for(const p of parts){ if(cur==null){break;} cur=cur[p]; } if(cur===undefined||cur===null){process.exit(3);} process.stdout.write(typeof cur==="string"?cur:JSON.stringify(cur));' "$expr" <<<"$json"
  else
    "$json_tool" -c 'import json,sys; obj=json.load(sys.stdin); cur=obj
for p in sys.argv[1].split("."):
  if cur is None: break
  cur=cur.get(p) if isinstance(cur,dict) else None
if cur is None: sys.exit(3)
print(cur if isinstance(cur,str) else json.dumps(cur))' "$expr" <<<"$json"
  fi
}

contains_line() {
  local needle="$1"
  shift
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done
  return 1
}

apply_placeholders() {
  local s="$1"
  local args_json="$2"
  require_json_tool
  local pairs
  if [ "$json_tool" = "node" ]; then
    pairs=$(node -e 'const fs=require("fs"); const a=JSON.parse(fs.readFileSync(0,"utf8")); for(const k of Object.keys(a||{})){ process.stdout.write(k+"="+String(a[k])+"\n"); }' <<<"$args_json" || true)
  else
    pairs=$("$json_tool" -c 'import json,sys; a=json.load(sys.stdin); 
[(print(f"{k}={a[k]}") ) for k in (a or {}).keys()]' <<<"$args_json" 2>/dev/null || true)
  fi

  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    k="${kv%%=*}"
    v="${kv#*=}"
    s="${s//\{$k\}/$v}"
  done <<<"$pairs"
  printf '%s' "$s"
}

run_pipeline() {
  local task_json="$1"
  local policy_json="$2"

  local pipeline_json
  pipeline_json=$(json_get "$task_json" "pinned_pipeline") || fail_json "Task spec missing pinned_pipeline"

  local allowed_effects_json="[]"
  if [ -n "$policy_json" ] && [ "$policy_json" != "null" ]; then
    allowed_effects_json=$(json_get "$policy_json" "allowed_effects" 2>/dev/null || printf '%s' '[]')
  fi

  # Create run row
  local run_id
  run_id=$(sql_one_json "INSERT INTO skill_system.runs(task_spec_id, status, started_at, effective_policy) VALUES ($(json_get "$task_json" "id"), 'running', NOW(), COALESCE('$policy_json'::jsonb,'{}'::jsonb)) RETURNING id;")
  run_id="${run_id##*$'\n'}"
  run_id="${run_id//[^0-9]/}"
  [ -n "$run_id" ] || fail_json "Failed to create run row"

  sql_one_json "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($run_id, 'info', 'run_started', '{"task_spec_id":' || $(json_get "$task_json" "id") || '}');" >/dev/null || true

  # Iterate steps: use node/python to stream each step JSON per line.
  require_json_tool
  local steps
  if [ "$json_tool" = "node" ]; then
    steps=$(node -e 'const fs=require("fs"); const t=JSON.parse(fs.readFileSync(0,"utf8")); const p=t.pinned_pipeline||[]; p.forEach(s=>process.stdout.write(JSON.stringify(s)+"\n"));' <<<"$task_json")
  else
    steps=$("$json_tool" -c 'import json,sys; t=json.load(sys.stdin); p=t.get("pinned_pipeline") or []; 
for s in p: print(json.dumps(s))' <<<"$task_json")
  fi

  local step_index=0
  local ok_steps=0
  local start_ts
  start_ts=$(date +%s)

  while IFS= read -r step; do
    [ -n "$step" ] || continue
    step_index=$((step_index+1))

    local skill op args
    skill=$(json_get "$step" "skill") || fail_json "Step missing skill"
    op=$(json_get "$step" "op") || fail_json "Step missing op"
    args=$(json_get "$step" "args" 2>/dev/null || printf '%s' '{}')

    local manifest_raw
    manifest_raw=$(extract_manifest_block "$skill" | tr -d '\r')
    [ -n "$manifest_raw" ] || fail_json "Missing router-manifest block for skill '$skill'"
    # JSON (valid YAML) expected
    local manifest_json
    manifest_json="$manifest_raw"

    # policy preflight (effects)
    if [ "$allowed_effects_json" != "[]" ] && [ "$allowed_effects_json" != "null" ]; then
      local eff
      while IFS= read -r eff; do
        [ -n "$eff" ] || continue
        # check eff in allowed_effects_json
        local allowed_lines
        if [ "$json_tool" = "node" ]; then
          allowed_lines=$(node -e 'const fs=require("fs"); const a=JSON.parse(fs.readFileSync(0,"utf8")); (a||[]).forEach(x=>process.stdout.write(String(x)+"\n"));' <<<"$allowed_effects_json")
        else
          allowed_lines=$("$json_tool" -c 'import json,sys; a=json.load(sys.stdin); [print(x) for x in (a or [])]' <<<"$allowed_effects_json")
        fi
        if ! contains_line "$eff" <<<"$allowed_lines"; then
          sql_one_json "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='policy_blocked:$eff' WHERE id=$run_id;" >/dev/null || true
          fail_json "Policy blocked effect '$eff' for step $step_index ($skill $op)"
        fi
      done < <(manifest_get_effects "$manifest_json" || true)
    fi

    # entrypoint argv
    local os_key="unix"
    if [ "${OS:-}" = "Windows_NT" ]; then
      os_key="windows"
    fi

    local argv_lines
    if ! argv_lines=$(manifest_get_entrypoint_argv "$manifest_json" "$op" "$os_key"); then
      sql_one_json "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='missing_entrypoint' WHERE id=$run_id;" >/dev/null || true
      fail_json "Missing entrypoint for $skill op=$op os=$os_key"
    fi

    local argv=()
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      a=$(apply_placeholders "$a" "$args")
      argv+=("$a")
    done <<<"$argv_lines"

    sql_one_json "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($run_id, 'info', 'step_started', ('{"index":$step_index,"skill":' || to_json('$skill') || ',"op":' || to_json('$op') || '}')::jsonb);" >/dev/null || true

    set +e
    local out
    local ec
    skill_dir="$skills_root/$skill"
    if [ ! -d "$skill_dir" ]; then
      set -e
      sql_one_json "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='skill_dir_missing' WHERE id=$run_id;" >/dev/null || true
      fail_json "Skill directory missing: $skill_dir"
    fi
    out=$(cd "$skill_dir" && "${argv[@]}" 2>&1)
    ec=$?
    set -e

    local last_line
    last_line=$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')
    if [ $ec -ne 0 ]; then
      sql_one_json "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($run_id, 'error', 'step_failed', ('{"index":$step_index,"exit_code":$ec}')::jsonb);" >/dev/null || true
      sql_one_json "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='step_failed' WHERE id=$run_id;" >/dev/null || true
      fail_json "Step failed ($skill $op) exit_code=$ec"
    fi
    if [ -z "$last_line" ] || [ "${last_line:0:1}" != "{" ]; then
      sql_one_json "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='missing_last_line_json' WHERE id=$run_id;" >/dev/null || true
      fail_json "Step output missing last-line JSON ($skill $op)"
    fi

    ok_steps=$((ok_steps+1))
    sql_one_json "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($run_id, 'info', 'step_succeeded', ('{"index":$step_index}')::jsonb);" >/dev/null || true
  done <<<"$steps"

  local end_ts
  end_ts=$(date +%s)
  local dur_ms=$(( (end_ts - start_ts) * 1000 ))

  sql_one_json "UPDATE skill_system.runs SET status='succeeded', ended_at=NOW(), metrics=jsonb_build_object('steps', $ok_steps, 'duration_ms', $dur_ms) WHERE id=$run_id;" >/dev/null || true
  sql_one_json "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($run_id, 'info', 'run_succeeded', ('{"steps":$ok_steps,"duration_ms":$dur_ms}')::jsonb);" >/dev/null || true

  printf '%s\n' "{\"status\":\"ok\",\"summary\":\"run_succeeded\",\"artifacts\":[],\"metrics\":{\"run_id\":$run_id,\"steps\":$ok_steps,\"duration_ms\":$dur_ms},\"errors\":[]}" 
}

usage() {
  cat <<'EOF'
Usage:
  scripts/router.sh run <task_spec_id>

Notes:
  - Requires psql.
  - Requires node or python for JSON parsing.
EOF
}

case "$cmd" in
  run)
    [ -n "$task_id" ] || { usage; exit 2; }
    task_json=$(get_task_spec_json "$task_id")
    [ -n "$task_json" ] && [ "$task_json" != "null" ] || fail_json "Task spec not found: $task_id"
    policy_id=$(json_get "$task_json" "policy_profile_id" 2>/dev/null || printf '%s' '')
    policy_json=""
    if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
      policy_json=$(get_policy_profile_json "$policy_id" || true)
    fi
    run_pipeline "$task_json" "$policy_json"
    ;;
  *)
    usage
    exit 2
    ;;
esac
