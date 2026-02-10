# Procedure: Extract Facets

Goal: produce a per-session facet YAML and store it to Postgres (`agent_memories`).

This procedure is intentionally mechanical so it can be repeated consistently.

## Step 0: Rate limit check (max 3 facets / 24h)

If you can run SQL directly, count facets in the last 24h for this user:

```sql
SELECT COUNT(*)
FROM agent_memories
WHERE deleted_at IS NULL
  AND category = 'insight-facet'
  AND tags @> ARRAY['user:<user>']
  AND created_at >= (NOW() - INTERVAL '24 hours');
```

If the count is >= 3:

- Do NOT store a new facet.
- Tell the user what you would have captured (1 short paragraph).
- Ask them to pick 1 session (by id/time) to record.

## Step 1: Load the session

Retrieve the session using available tooling:

- **OpenCode**: Use `session_list` to find sessions, then `session_read(session_id=...)` to load transcript.
- **Claude Code**: Use `/insights` or read from `~/.claude/projects/` session files.
- **Other**: Accept `session_id` as input parameter if transcript is provided directly.

Collect the session metadata:
- `session_id` — from the session tool or user input
- `timestamp` — ISO 8601 UTC, use session's last message time
- `user` — from AGENTS.md, session metadata, or ask

## Step 2: Run the facet extraction prompt

Use: `prompts/facet-extraction.md`

Input the transcript and metadata.

Output must be a single YAML document matching `schema/facet.yaml`.

## Step 3: Validate the facet

Before storing:

- Required fields present:
  - `session_id`, `timestamp`, `user`, `underlying_goal`, `session_type`, `outcome`, `brief_summary`, `user_signals`, `agent_performance`
- Enums are valid (see `schema/facet.yaml`).
- If `proposed_adjustments` exists:
  - Personality direction is exactly `+0.05` or `-0.05`
  - Emotion direction is exactly `+0.1` or `-0.1`
  - Evidence is concrete (points to something observable)

If validation fails, fix the facet YAML before storing.

## Step 4: Store facet to agent_memories

Store the facet YAML text as the memory `content`.

```sql
SELECT store_memory(
  'episodic',
  'insight-facet',
  ARRAY[
    'session:<session_id>',
    'user:<user>'
  ],
  'Session Facet: <brief_summary>',
  '<facet YAML>',
  '{"session_type": "<session_type>", "outcome": "<outcome>"}',
  'insight-agent',
  '<session_id>',
  5.0
);
```

## Step 5: Transparency message

Tell the user:

- What signals you recorded (1-3 bullets).
- What you plan to adjust (if any), and why.
- That you only apply matrix changes after repeated evidence (3+ similar observations).
