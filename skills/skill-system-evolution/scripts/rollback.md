# Procedure: Rollback Evolution
Goal: restore a prior soul profile or recipe content from a stored evolution snapshot, then record the rollback as a new snapshot.

Inputs required:
- `{user}`
- `{version_tag}` to restore

## Step 0: Validate the snapshot exists
Run (fill `{version_tag}`):
```sql
SELECT id, content, tags, created_at
FROM agent_memories
WHERE category = 'evolution-snapshot' AND 'version:{version_tag}' = ANY(tags)
LIMIT 1;
```

If no row returned:
- STOP and report that the version_tag is unknown.

## Step 1: Read snapshot content
The snapshot YAML is stored in `content`.
Parse it according to:
- `skill/skills/skill-system-evolution/schema/evolution-snapshot.yaml`

Extract:
- `target`
- `snapshot_data`
- `changes` (for reporting)

## Step 2: Determine target type
From tags, find:
- `target:soul` or `target:recipe` or `target:both`

If ambiguous:
- Prefer the snapshot YAML's `target` field.

## Step 3: Restore artifacts

### If target is `soul`
1. Write `snapshot_data` back to:
   - `skill/skills/skill-system-soul/profiles/{user}.md`
2. Update soul-state to match the restored profile intent:
   - If the snapshot includes explicit state values, restore them.
   - If not present, derive minimal state updates consistent with the restored profile.

### If target is `recipe`
1. Determine which recipe file(s) are included.
   - Prefer filenames present in `snapshot_data` separators (if used).
2. Write restored YAML content back to the corresponding file(s) under:
   - `skill/skills/skill-system-workflow/recipes/`

### If target is `both`
Perform both restoration paths.

## Step 4: Create a rollback snapshot
Create a NEW snapshot YAML (do not overwrite the old one):
- `rollback_from`: set to the restored `{version_tag}`
- `trigger`: "Rollback to {version_tag}"
- `snapshot_data`: the full restored artifact content written to disk

Version tag guidance:
- Use next sequential `vN_..._YYYYMMDD` for the rollback action.
- Set `target` to the restored target.

## Step 5: Store rollback snapshot to Postgres
Use `store_memory()`:
```sql
SELECT store_memory('episodic', 'evolution-snapshot',
  ARRAY['user:{user}', 'target:{target}', 'version:{new_version_tag}'],
  'Evolution Snapshot: {new_version_tag}',
  '{full rollback snapshot YAML}',
  '{"version_tag": "{new_version_tag}", "target": "{target}", "timestamp": "{iso}"}',
  'evolution-agent', NULL, 8.0);
```

## Step 6: Report
Report:
- What was restored (target + files)
- Restored from version_tag
- New rollback snapshot version_tag
- Any notable differences (from `changes`)
