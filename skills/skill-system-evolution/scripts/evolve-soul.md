# Procedure: Evolve Soul
Goal: propose and apply a conservative soul evolution for a single user, storing a versioned snapshot in Postgres.

Artifacts involved:
- Prompts: `skill/skills/skill-system-evolution/prompts/evolution-planning.md`
- Schemas: `skill/skills/skill-system-evolution/schema/evolution-plan.yaml`, `skill/skills/skill-system-evolution/schema/evolution-snapshot.yaml`
- Storage: Postgres `agent_memories` table via `store_memory()`
- Output file: `skill/skills/skill-system-soul/profiles/{user}.md`

Versioning constraints:
- Max 1 evolution per day per user (24h window).
- Version tag format: `v{N}_{target}_{timestamp}` (example: `v3_soul_20260211`).

## Step 0: Rate limit check (24h)
Run (fill `{user}`):
```sql
SELECT id, created_at, title FROM agent_memories
WHERE category = 'evolution-snapshot' AND 'user:{user}' = ANY(tags)
AND created_at >= (NOW() - INTERVAL '24 hours')
ORDER BY created_at DESC LIMIT 1;
```

Decision:
- If a row is returned: STOP. Report the most recent snapshot id/title/time and do not evolve.
- If no row: continue.

## Step 1: Load current soul-state
Query the latest soul-state for this user:
```sql
SELECT id, created_at, title, content
FROM agent_memories
WHERE category = 'soul-state' AND 'user:{user}' = ANY(tags)
ORDER BY created_at DESC
LIMIT 1;
```

If missing:
- Use the default/balanced baseline state defined by the soul system (do not invent new fields).

## Step 2: Load recent facets (last 50)
```sql
SELECT id, created_at, title, content
FROM agent_memories
WHERE category = 'insight-facet' AND 'user:{user}' = ANY(tags)
ORDER BY created_at DESC
LIMIT 50;
```

## Step 3: Load current soul profile markdown
Read in this order:
1. `skill/skills/skill-system-soul/profiles/{user}.md` if it exists
2. Otherwise `skill/skills/skill-system-soul/profiles/balanced.md`

## Step 4: Generate an evolution plan
Use the prompt:
- `skill/skills/skill-system-evolution/prompts/evolution-planning.md`

Inputs to provide:
- The 50 facets (from Step 2)
- The soul-state YAML (from Step 1)
- The current profile markdown (from Step 3)

Output required:
- A single YAML document that matches `skill/skills/skill-system-evolution/schema/evolution-plan.yaml`

## Step 5: Safety check (approval gating)
Evaluate the plan:
- If any proposed change has `drift_from_baseline > 0.5`, set:
  - `requires_approval: true`
  - `reason: "Personality drift exceeds safety limit (> 0.5) ..."`

If `requires_approval: true`:
- Present the plan to the user verbatim.
- Wait for explicit confirmation before applying.

## Step 6: Apply changes
1. Update soul-state YAML values according to the plan.
2. Regenerate the Layer 3 soul profile markdown for the user.
3. Write the updated profile to:
   - `skill/skills/skill-system-soul/profiles/{user}.md`

Constraints:
- Apply only the fields explicitly listed in the plan.
- Do not introduce new dimensions without evidence.

## Step 7: Create an evolution snapshot (YAML)
Construct a snapshot YAML matching `skill/skills/skill-system-evolution/schema/evolution-snapshot.yaml`.

Guidelines:
- `version_tag`: next sequential `vN` for this user and target `soul` using `YYYYMMDD` timestamp.
- `trigger`: one sentence describing the repeated pattern that caused the evolution.
- `changes`: one entry per field change; include evidence references (session ids, facet ids).
- `snapshot_data`: the full updated profile markdown.
- `rollback_from`: null.

## Step 8: Store snapshot to Postgres
Store the full snapshot YAML (as a single string) using `store_memory()`.

Template (fill placeholders):
```sql
SELECT store_memory('episodic', 'evolution-snapshot',
  ARRAY['user:{user}', 'target:{target}', 'version:{version_tag}'],
  'Evolution Snapshot: {version_tag}',
  '{full snapshot YAML}',
  '{"version_tag": "{version_tag}", "target": "{target}", "timestamp": "{iso}"}',
  'evolution-agent', NULL, 8.0);
```

## Step 9: Report
Report in a tight, evidence-first format:
- What changed (dimension/field: old -> new)
- Why (3+ evidence points)
- Safety status (approval required or not)
- Version tag stored

## How to run SQL with psql (Windows)
Use the configured psql path (example):
```text
"C:\Program Files\PostgreSQL\18\bin\psql.exe" "postgresql://postgres:36795379@localhost:5432/agent_memory" -c "<SQL>"
```
