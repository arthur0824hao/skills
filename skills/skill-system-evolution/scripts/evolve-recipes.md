# Procedure: Evolve Recipes
Goal: evolve workflow recipes conservatively based on workflow facets, storing versioned snapshots in Postgres.

Artifacts involved:
- Prompt: `skill/skills/skill-system-evolution/prompts/recipe-evolution.md`
- Recipes: `skill/skills/skill-system-workflow/recipes/*.yaml`
- Storage: Postgres `agent_memories` via `store_memory()`

Versioning constraints:
- Max 1 evolution per day per user (shared limit with soul evolution).
- Version tag format: `v{N}_{target}_{timestamp}` (example: `v4_recipe_20260211`).

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

## Step 1: Load workflow-related facets
Query recent facets and filter for workflow/recipe signals (either in SQL via text match or client-side after fetching):
```sql
SELECT id, created_at, title, content
FROM agent_memories
WHERE category = 'insight-facet' AND 'user:{user}' = ANY(tags)
ORDER BY created_at DESC
LIMIT 200;
```

Filter criteria (examples):
- Mentions of recipe ids/names
- Repeated retries, step confusion, or missing prerequisites
- Long-running sessions that stall at the same step

## Step 2: Load current recipes
Read all YAML files in:
- `skill/skills/skill-system-workflow/recipes/`

## Step 3: Analyze with the recipe evolution prompt
Use:
- `skill/skills/skill-system-evolution/prompts/recipe-evolution.md`

Provide:
- Filtered workflow facets (from Step 1)
- Full recipe contents (from Step 2)

Expected output:
- Markdown plan listing candidates and unified diffs.

## Step 4: Validate proposed changes
For each candidate recipe diff:
- Confirm 3+ supporting observations are cited.
- Confirm the change is minimal and addresses the failure mode.
- Safety rule: never delete recipes.

Deprecation guidance (instead of delete):
- Keep the recipe file.
- Add a clear deprecation note/flag.
- Point to a replacement recipe if applicable.

## Step 5: Apply changes to recipe files
1. Apply diffs to the corresponding recipe YAML files.
2. Preserve formatting conventions already present in the recipe.
3. Avoid broad renames unless strictly required.

## Step 6: Create evolution snapshot
Create a snapshot YAML matching `skill/skills/skill-system-evolution/schema/evolution-snapshot.yaml`.

Guidelines:
- `target`: `recipe`.
- `snapshot_data`: store the full updated content for each modified recipe.
  - If multiple recipes changed, concatenate them with clear separators and filenames.
- `changes`: list per-field changes with evidence references.

## Step 7: Store snapshot to Postgres
Use `store_memory()` with tags and metadata:
```sql
SELECT store_memory('episodic', 'evolution-snapshot',
  ARRAY['user:{user}', 'target:{target}', 'version:{version_tag}'],
  'Evolution Snapshot: {version_tag}',
  '{full snapshot YAML}',
  '{"version_tag": "{version_tag}", "target": "{target}", "timestamp": "{iso}"}',
  'evolution-agent', NULL, 8.0);
```

## Step 8: Report
Report:
- Recipes changed (file paths)
- What changed (brief)
- Evidence (3+ references per recipe)
- Version tag stored
