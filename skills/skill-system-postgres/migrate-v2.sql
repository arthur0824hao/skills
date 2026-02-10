-- Skill System v2 Migration
-- Simplifies schema for Agent-as-Router model:
--   - runs.task_spec_id becomes nullable (Agent-initiated runs don't need task_specs)
--   - runs gains goal, agent_id, policy_profile_id columns
--   - task_specs and artifacts tables are deprecated (not dropped, for safety)

BEGIN;

ALTER TABLE skill_system.runs
  ALTER COLUMN task_spec_id DROP NOT NULL;

ALTER TABLE skill_system.runs
  DROP CONSTRAINT IF EXISTS runs_task_spec_id_fkey;

DO $$ BEGIN
  ALTER TABLE skill_system.runs ADD COLUMN goal TEXT;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE skill_system.runs ADD COLUMN agent_id TEXT;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE skill_system.runs ADD COLUMN policy_profile_id BIGINT REFERENCES skill_system.policy_profiles(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_runs_agent_id ON skill_system.runs(agent_id) WHERE agent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_runs_status ON skill_system.runs(status);

COMMIT;
