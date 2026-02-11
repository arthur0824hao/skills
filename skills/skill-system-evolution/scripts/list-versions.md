# Procedure: List Evolution Versions
Goal: list stored evolution snapshots for a user, optionally filtered by target, in most-recent-first order.

## Step 0: Query snapshots
Run (fill `{user}`):
```sql
SELECT id, created_at, title, tags
FROM agent_memories
WHERE category = 'evolution-snapshot' AND 'user:{user}' = ANY(tags)
ORDER BY created_at DESC LIMIT 50;
```

Optional target filter:
- After fetching rows, filter by tags containing:
  - `target:soul`
  - `target:recipe`
  - `target:both`

## Step 1: Extract fields
For each row:
- `version_tag`: parse from tags entry `version:{version_tag}`
- `target`: parse from tags entry `target:{target}`
- `created_at`: from the row
- `summary`: from `title`

## Step 2: Format output table
Render as:
```text
version_tag | target | created_at | summary
```

Sorting:
- Most recent first (already sorted by SQL).

## Notes
- If more than 50 versions exist, paginate by adjusting LIMIT/OFFSET.
