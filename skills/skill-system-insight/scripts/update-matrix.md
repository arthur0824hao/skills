# Procedure: Update Dual Matrix (Soul State)

Goal: take one stored facet and update the persisted soul state (dual matrix) with confidence gating.

This updates Layer 2 only. Layer 3 profile synthesis is a separate step.

## Inputs

- Current soul state YAML (`category='soul-state'`) for the user
- One facet YAML (`category='insight-facet'`) for the user

## Algorithm

### 1) Read proposed adjustments

From the facet YAML:

- `proposed_adjustments.personality` (optional)
- `proposed_adjustments.emotion` (optional)

If neither exists: still increment counters (see step 5) and re-save state.

### 2) Accumulate evidence into buffers (no value change yet)

For each proposed adjustment:

- Determine direction bucket:
  - `+` if direction is `+0.05` / `+0.1`
  - `-` if direction is `-0.05` / `-0.1`
- Append the facet's `evidence` string to the buffer's `evidence` list.
- Increment that direction counter (`plus` or `minus`).

This is the "3+ similar observations" mechanism.

### 3) Check confidence threshold

For each affected dimension:

- If `buffer.plus >= 3`:
  - Apply a single step in the positive direction
  - Decrement `buffer.plus` by 3
  - Clear or trim `buffer.evidence` (keep last 3 evidence strings)

- If `buffer.minus >= 3`:
  - Apply a single step in the negative direction
  - Decrement `buffer.minus` by 3
  - Clear or trim `buffer.evidence` (keep last 3 evidence strings)

Only apply one step per update pass per dimension.

### 4) Apply adjustment (when threshold passes)

When applying:

Personality dimension:

- `value = clamp(value + step, 0.0, 1.0)` where `step` is +/- 0.05
- `observations += 1`
- `confidence = clamp(confidence + 1, 0, 10)`
- Append a context line to `context`, e.g.:
  - "2026-02-10: +0.05 directness (3x evidence: prefers terse answers; wants execution-first)"

Emotion dimension:

- `baseline = clamp(baseline + step, 0.0, 1.0)` where `step` is +/- 0.1
- `value = baseline` (this system does not do real-time mood tracking)
- Append a context line to `context`, e.g.:
  - "2026-02-10: +0.1 caution (3x evidence: asked to verify before changing files)"

### 5) Update counters

- `total_insights += 1`
- `synthesis.facets_since_last_synthesis += 1`
- `last_updated = now()`

### 6) Check synthesis trigger

Set `synthesis.pending = true` if ANY of the following hold:

1) Personality drift: any personality dimension has drifted >= 0.3 from the neutral baseline (0.5)
   - i.e. `abs(value - 0.5) >= 0.3`
2) Insight volume: `synthesis.facets_since_last_synthesis >= 30`

### 7) Save updated soul state

Store the full soul-state YAML as text into `agent_memories`:

```sql
SELECT store_memory(
  'semantic',
  'soul-state',
  ARRAY['user:<user>', 'matrix'],
  'Soul State: <user>',
  '<soul-state YAML>',
  '{"total_insights": <N>, "last_updated": "<iso>"}',
  'insight-agent',
  NULL,
  9.0
);
```

## Transparency requirement

After an update pass, tell the user:

- What evidence was accumulated (even if threshold not met)
- Whether any value changed (and by how much)
- Whether synthesis is now pending
