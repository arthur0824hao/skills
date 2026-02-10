---
name: skill-system-postgres
description: "Postgres-backed observability and policy store for the skill system. Provides tables for policy profiles (effect allowlists), skill execution runs, and step-level events. Use when setting up the skill system database or querying execution history."
license: MIT
compatibility: opencode
metadata:
  storage: postgresql
  os: windows, linux, macos
---

# Skill System (Postgres State)

Database schema for skill system observability and policy.

## Install

```bash
psql -U postgres -d agent_memory -v ON_ERROR_STOP=1 -f init.sql
```

```powershell
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -d agent_memory -v "ON_ERROR_STOP=1" -f init.sql
```

For existing v1 installations, also run `migrate-v2.sql`.

## Tables

- `skill_system.policy_profiles` — effect allowlists (what skills are allowed to do)
- `skill_system.runs` — execution records (goal, agent, status, duration, metrics)
- `skill_system.run_events` — step-level event log (which skill, which op, result)

## Usage

The Agent writes to these tables as instructed by the Router skill. This skill does not execute anything — it's a state store.
