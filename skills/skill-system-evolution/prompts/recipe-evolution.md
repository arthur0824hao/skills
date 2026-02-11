# Prompt: Recipe Evolution (Workflow)
Purpose: Evaluate workflow recipe effectiveness using workflow-related facets and current recipes. Propose conservative modifications with explicit before/after diffs.

Style constraints:
- Evidence-based, post-incident style: show the pattern, show its impact, then propose a minimal fix.
- Only propose a modification when supported by 3+ data points.
- Never delete recipes. You may deprecate by marking status/notes and/or reducing recommendation priority.

## Inputs
You will be given:
1. Workflow facets: sessions where recipes were used or attempted (signals in facets such as recipe name mentions, friction markers, repeated retries, timeouts, confusion).
2. Current recipes: the full contents of `skill-system-workflow/recipes/*.yaml`.

## Task
1. Build a per-recipe scorecard:
   - Usage frequency (approximate from facets)
   - Friction frequency (count occurrences of confusion, rework, repeated clarifications)
   - Outcome quality signals (success markers vs. incomplete/abandoned sessions)
2. Identify candidates:
   - Underused recipes: never/rarely used despite being relevant.
   - Friction-heavy recipes: recurring confusion or repeated corrective steps.
3. For each candidate (must have 3+ supporting observations):
   - Describe the recurring failure mode with evidence references.
   - Propose the smallest change that addresses the failure mode.
   - Provide a before/after diff (unified diff style) for the recipe YAML.
   - If deprecating: keep recipe file, add explicit deprecation metadata and point to the replacement.
4. Output a single plan document (Markdown is fine) with:
   - A short header per recipe
   - Evidence section with references
   - Proposed change
   - Before/after diff

## Output
Return a Markdown document with the following sections, in this order:
1. "Overview" (brief)
2. "Candidates" (list of recipe ids/names)
3. For each candidate: "Evidence", "Proposed Change", "Diff"

## Rules
- Threshold: 3+ data points before modifying.
- No deletions. Only modify or deprecate.
- Avoid large refactors; prefer targeted edits (clarify prerequisites, reorder steps, add safety checks, add defaults).

## Diff Format
Use unified diff blocks:
```diff
--- a/skill/skills/skill-system-workflow/recipes/{recipe}.yaml
+++ b/skill/skills/skill-system-workflow/recipes/{recipe}.yaml
@@
-old
+new
```
