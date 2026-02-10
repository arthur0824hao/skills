#!/usr/bin/env bash
# build-index.sh — Scan all sibling skills for skill-manifest blocks → produce skills-index.json
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_root="$(cd "$script_dir/../.." && pwd)"
out_file="${1:-$skills_root/skills-index.json}"

# Detect JSON tool
json_tool=""
if command -v node >/dev/null 2>&1; then
  json_tool="node"
elif command -v python3 >/dev/null 2>&1; then
  json_tool="python3"
elif command -v python >/dev/null 2>&1; then
  json_tool="python"
fi

if [ -z "$json_tool" ]; then
  echo '{"error":"No JSON tool found (need node or python)"}' >&2
  exit 1
fi

# Extract manifest block from SKILL.md (try skill-manifest first, fallback to router-manifest)
extract_manifest() {
  local md="$1"
  local block=""
  # Try skill-manifest first
  block=$(awk '
    BEGIN{inblock=0}
    /^```skill-manifest[[:space:]]*$/ {inblock=1; next}
    inblock && /^```[[:space:]]*$/ {exit}
    inblock {print}
  ' "$md")
  # Fallback to router-manifest
  if [ -z "$block" ]; then
    block=$(awk '
      BEGIN{inblock=0}
      /^```router-manifest[[:space:]]*$/ {inblock=1; next}
      inblock && /^```[[:space:]]*$/ {exit}
      inblock {print}
    ' "$md")
  fi
  printf '%s' "$block"
}

# Collect manifests
manifests="[]"
for skill_dir in "$skills_root"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name="$(basename "$skill_dir")"
  md="$skill_dir/SKILL.md"
  [ -f "$md" ] || continue

  block=$(extract_manifest "$md" | tr -d '\r')
  [ -n "$block" ] || continue

  # Validate JSON
  if [ "$json_tool" = "node" ]; then
    if ! node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' <<<"$block" 2>/dev/null; then
      echo "WARN: Invalid manifest JSON in $skill_name, skipping" >&2
      continue
    fi
  else
    if ! "$json_tool" -c 'import json,sys; json.load(sys.stdin)' <<<"$block" 2>/dev/null; then
      echo "WARN: Invalid manifest JSON in $skill_name, skipping" >&2
      continue
    fi
  fi

  # Append to manifests array
  if [ "$json_tool" = "node" ]; then
    manifests=$(node -e '
      const fs = require("fs");
      const arr = JSON.parse(process.argv[1]);
      const m = JSON.parse(fs.readFileSync(0, "utf8"));
      m._dir = process.argv[2];
      arr.push(m);
      process.stdout.write(JSON.stringify(arr));
    ' "$manifests" "$skill_name" <<<"$block")
  else
    manifests=$("$json_tool" -c '
import json, sys
arr = json.loads(sys.argv[1])
m = json.load(sys.stdin)
m["_dir"] = sys.argv[2]
arr.append(m)
print(json.dumps(arr))
' "$manifests" "$skill_name" <<<"$block")
  fi
done

# Build index
if [ "$json_tool" = "node" ]; then
  node -e '
const manifests = JSON.parse(process.argv[1]);
const outFile = process.argv[2];
const fs = require("fs");

const index = {
  schema_version: "2.0",
  generated_at: new Date().toISOString(),
  skills: {},
  capability_index: {}
};

for (const m of manifests) {
  const id = m.id || m._dir;
  const dir = m._dir;
  const caps = m.capabilities || [];
  const effects = m.effects || [];
  const ops = {};
  for (const [name, op] of Object.entries(m.operations || m.entrypoints || {})) {
    ops[name] = {
      description: op.description || "",
      input_params: Object.keys(op.input || {}),
    };
  }
  index.skills[id] = {
    dir: dir,
    version: m.version || "0.0.0",
    capabilities: caps,
    effects: effects,
    operations: ops
  };
  for (const cap of caps) {
    if (!index.capability_index[cap]) index.capability_index[cap] = [];
    if (!index.capability_index[cap].includes(id)) index.capability_index[cap].push(id);
  }
}

fs.writeFileSync(outFile, JSON.stringify(index, null, 2) + "\n");
console.log("Index written: " + outFile + " (" + manifests.length + " skills)");
' "$manifests" "$out_file"
else
  "$json_tool" -c '
import json, sys, os
from datetime import datetime, timezone

manifests = json.loads(sys.argv[1])
out_file = sys.argv[2]

index = {
    "schema_version": "2.0",
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "skills": {},
    "capability_index": {}
}

for m in manifests:
    sid = m.get("id", m.get("_dir", "unknown"))
    d = m.get("_dir", sid)
    caps = m.get("capabilities", [])
    effects = m.get("effects", [])
    raw_ops = m.get("operations", m.get("entrypoints", {}))
    ops = {}
    for name, op in raw_ops.items():
        if isinstance(op, dict) and "description" in op:
            ops[name] = {
                "description": op.get("description", ""),
                "input_params": list((op.get("input") or {}).keys()),
            }
        # Skip v1-style flat entrypoints without description

    index["skills"][sid] = {
        "dir": d,
        "version": m.get("version", "0.0.0"),
        "capabilities": caps,
        "effects": effects,
        "operations": ops
    }
    for cap in caps:
        if cap not in index["capability_index"]:
            index["capability_index"][cap] = []
        if sid not in index["capability_index"][cap]:
            index["capability_index"][cap].append(sid)

with open(out_file, "w") as f:
    json.dump(index, f, indent=2)
    f.write("\n")
print(f"Index written: {out_file} ({len(manifests)} skills)")
' "$manifests" "$out_file"
fi
