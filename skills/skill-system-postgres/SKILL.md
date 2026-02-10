---
name: skill-system-postgres
description: Use when you need a Postgres-backed state store for a Router-based skill system (task specs, policy profiles, runs, events, artifacts) across Windows and Linux.
license: MIT
compatibility: opencode
metadata:
  storage: postgresql
  os: windows, linux, macos
---

# Skill System (Postgres State)

This skill defines the database schema for a Router-driven skill system.

It is intentionally small:

- Task specs live in Postgres (referenced by DB row id)
- Policy profiles (allowlist-first) live in Postgres
- Router runs write events + artifacts for observability and replay

## Install / Apply Schema

The schema is created by `init.sql` in this directory.

Linux/macOS:

```bash
psql -U postgres -d agent_memory -v ON_ERROR_STOP=1 -f init.sql
```

Windows (adjust the path to `psql.exe`):

```powershell
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d agent_memory -v "ON_ERROR_STOP=1" -f init.sql
```

## Data Model (MVP)

- `skill_system.policy_profiles`: allowlists for effects/exec/write-roots
- `skill_system.task_specs`: Router inputs (goal/workspace/inputs/verification/pinned_pipeline/budgets)
- `skill_system.runs`: execution records with an effective policy snapshot
- `skill_system.run_events`: JSON events for observability
- `skill_system.artifacts`: output file references and metadata

## Notes

- This skill does not run anything by itself.
- Use it together with the Router skill that reads `task_specs` and executes a pinned pipeline.
