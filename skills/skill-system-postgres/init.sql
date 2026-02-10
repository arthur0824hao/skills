-- Skill System (Postgres) - state schema for Router-driven skill execution.
--
-- This file is designed to be safe to re-run.

BEGIN;

CREATE SCHEMA IF NOT EXISTS skill_system;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE n.nspname = 'skill_system' AND t.typname = 'run_status') THEN
    CREATE TYPE skill_system.run_status AS ENUM (
      'queued',
      'running',
      'succeeded',
      'failed',
      'cancelled'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS skill_system.policy_profiles (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  allowed_effects TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  allowed_exec TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  allowed_write_roots TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS skill_system.task_specs (
  id BIGSERIAL PRIMARY KEY,
  goal TEXT NOT NULL,
  workspace JSONB NOT NULL DEFAULT '{}'::jsonb,
  inputs JSONB NOT NULL DEFAULT '{}'::jsonb,
  verification JSONB NOT NULL DEFAULT '{}'::jsonb,
  pinned_pipeline JSONB NOT NULL DEFAULT '[]'::jsonb,
  budgets JSONB NOT NULL DEFAULT '{}'::jsonb,
  policy_profile_id BIGINT NULL REFERENCES skill_system.policy_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS skill_system.runs (
  id BIGSERIAL PRIMARY KEY,
  task_spec_id BIGINT NOT NULL REFERENCES skill_system.task_specs(id) ON DELETE CASCADE,
  status skill_system.run_status NOT NULL DEFAULT 'queued',
  started_at TIMESTAMPTZ NULL,
  ended_at TIMESTAMPTZ NULL,
  effective_policy JSONB NOT NULL DEFAULT '{}'::jsonb,
  metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
  error TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS skill_system.run_events (
  id BIGSERIAL PRIMARY KEY,
  run_id BIGINT NOT NULL REFERENCES skill_system.runs(id) ON DELETE CASCADE,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  level TEXT NOT NULL DEFAULT 'info',
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS skill_system.artifacts (
  id BIGSERIAL PRIMARY KEY,
  run_id BIGINT NOT NULL REFERENCES skill_system.runs(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  path TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_task_specs_policy_profile_id ON skill_system.task_specs(policy_profile_id);
CREATE INDEX IF NOT EXISTS idx_runs_task_spec_id ON skill_system.runs(task_spec_id);
CREATE INDEX IF NOT EXISTS idx_run_events_run_id ON skill_system.run_events(run_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_run_id ON skill_system.artifacts(run_id);

COMMIT;
