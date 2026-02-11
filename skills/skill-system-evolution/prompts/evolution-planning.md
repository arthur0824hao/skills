# Prompt: Evolution Planning (Soul)
Purpose: Analyze recent insight facets and current soul artifacts to propose a conservative, evidence-backed evolution plan.

Style constraints:
- Write like a post-incident review: evidence-first, specific, no speculation.
- Only propose a change if supported by 3+ consistent observations.
- Respect the drift safety limit: if drift_from_baseline > 0.5 for any proposed change, mark requires_approval=true.

## Inputs
You will be given:
1. Recent facets: the last 50 entries (category `insight-facet`) for this user.
2. Current soul-state: the latest stored YAML (category `soul-state`) for this user.
3. Current soul profile: the current Layer 3 profile markdown for this user (or `balanced.md` if no user profile exists).

## Task
1. Extract repeated, consistent behavioral signals from the facets.
2. Map signals to candidate evolution dimensions (e.g., communication style, autonomy, risk tolerance, verbosity, verification strictness).
3. For each candidate dimension:
   - Count evidence points (must be >= 3, consistent direction).
   - Summarize evidence with concrete excerpts (session ids, timestamps, and short quotes or paraphrases from facets).
   - Determine the current value from soul-state/profile.
   - Propose a new value if and only if evidence supports it.
   - Estimate drift from a 0.5 baseline (or from the system's defined baseline for that field) as a number.
4. Decide target:
   - `soul` if changes affect soul-state/profile only.
   - `recipe` if changes affect workflow recipes only.
   - `both` only if there is strong evidence for each target independently.
5. Produce a single YAML document that matches `schema/evolution-plan.yaml`.

## Output
Return ONLY valid YAML for an Evolution Plan. Do not wrap in Markdown.

### Output Template (YAML)
```yaml
schema_version: 1
title: "Evolution Plan"
user: "{user}"
target: soul
proposed_at: "{iso_8601}"
requires_approval: false
reason: ""
proposed_changes:
  - dimension: "{dimension_name}"
    current_value: {any}
    proposed_value: {any}
    evidence_count: 3
    evidence_summary: "{short, evidence-based summary with references}"
    drift_from_baseline: 0.15
estimated_impact: "{brief description of expected improvements and tradeoffs}"
```

## Evidence Rules
- Consistency: at least 3 observations pointing in the same direction.
- Relevance: each observation must be directly about the proposed dimension.
- Traceability: include references (e.g., `ses_...`, timestamps, facet titles).
- Conservatism: if the evidence is mixed or weak, leave the dimension unchanged.

## Drift Safety Rule
- If any `drift_from_baseline` > 0.5, set:
  - `requires_approval: true`
  - `reason: "Personality drift exceeds safety limit (> 0.5) for dimension(s): ..."`

## Common Failure Modes (Avoid)
- Making changes based on 1-2 loud sessions.
- Inferring motives or intent not present in facets.
- Changing multiple dimensions when one would address the issue.
- Producing prose instead of YAML.
