# Procedure: Synthesize Layer 3 Profile

Goal: regenerate a user-specific Soul profile (Layer 3) from Layer 1 + Layer 2 + recent facets.

## Preconditions (synthesis trigger)

Only run when at least one trigger fires:

- `synthesis.pending == true`, OR
- Any personality dimension drifted >= 0.3 from 0.5, OR
- `synthesis.facets_since_last_synthesis >= 30`

If none fire, do not synthesize.

## Step 1: Load inputs

- Base profile (Layer 1):
  - `skill/skills/skill-system-soul/profiles/balanced.md`
- Current soul state (Layer 2):
  - latest `category='soul-state'` for user
- Recent facets:
  - last 50 memories where `category='insight-facet'` and `tags` contains `user:<user>`

## Step 2: Generate the profile

Use: `prompts/soul-synthesis.md`

Provide the three inputs. Ensure the output:

- Starts with `# Soul: <user>`
- Uses the same 6 sections as the base profile
- Is concrete and specific to this user

## Step 3: Write profile file

Write the generated profile markdown to:

- `skill/skills/skill-system-soul/profiles/<user>.md`

This is the Layer 3 projection.

## Step 4: Reset synthesis counters

Update the soul state YAML:

- `synthesis.pending = false`
- `synthesis.last_synthesized_at = now()`
- `synthesis.syntheses_count += 1`
- `synthesis.facets_since_last_synthesis = 0`

Store the updated soul state back to `agent_memories` (same pattern as `scripts/update-matrix.md`).

## Step 5: Store synthesis event (optional but recommended)

Record a short episodic memory so you can audit why a profile changed:

```sql
SELECT store_memory(
  'episodic',
  'soul-synthesis',
  ARRAY['user:<user>'],
  'Soul Synthesis: <user>',
  'Generated Layer 3 profile from matrix + recent facets.',
  '{"facets_used": 50}',
  'insight-agent',
  NULL,
  6.0
);
```
