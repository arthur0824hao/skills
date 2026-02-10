---
name: skill-system-router
description: Use when you need to execute a DB-stored pinned pipeline of skills (Windows+Linux) with allowlist-first policy preflight and last-line JSON stdout.
license: MIT
compatibility: opencode
metadata:
  storage: postgresql
  os: windows, linux, macos
---

# Skill System Router

This skill provides a small cross-platform Router runtime.

Design constraints (MVP):

- Task specs are stored in Postgres and referenced by DB row id.
- Execution is deterministic: a `pinned_pipeline` (array of steps) is executed in order.
- Policy is allowlist-first: steps declare `effects`; policy profiles allow or block them.
- Each executed step is expected to emit a machine-parsable JSON object on the **last line** of stdout.

## Inputs (Task Spec Row)

Router reads a row from `skill_system.task_specs` with the shape:

- `goal` (text)
- `workspace` (jsonb)
- `inputs` (jsonb)
- `verification` (jsonb)
- `pinned_pipeline` (jsonb array)
- `budgets` (jsonb)
- `policy_profile_id` (nullable)

### `pinned_pipeline` step shape (MVP)

Each step is an object:

```json
{
  "skill": "skill-system-memory",
  "op": "mem.search",
  "args": { "query": "pgvector", "limit": "5" }
}
```

## Skill Manifests

OpenCode discovery only recognizes `SKILL.md`. To keep Router machine-readable, each skill may embed a Router manifest block.

Router looks for a fenced block that starts with:

```
```router-manifest
...
```
```

For portability, the content should be JSON (valid YAML) so it can be parsed without adding a YAML dependency.

## Run

Linux/macOS:

```bash
bash "scripts/router.sh" run 123
```

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\router.ps1" run 123
```

Environment variables (optional): `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`.
