// OpenCode plugin template for this skill.
// Install: copy to ~/.config/opencode/plugins/ (Windows: %USERPROFILE%\.config\opencode\plugins\)

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

/** @type {import('@opencode-ai/plugin').Plugin} */
export const AgentMemorySystemsPostgres = async ({ $, directory, client }) => {
  const home = os.homedir()
  const stateDir = path.join(home, '.config', 'opencode', 'agent-memory-systems-postgres')
  const eventsPath = path.join(stateDir, 'compaction-events.jsonl')
  const setupPath = path.join(stateDir, 'setup.json')

  const hasSetup = () => {
    try { return fs.existsSync(setupPath) } catch { return false }
  }

  const ensureDir = () => {
    try { fs.mkdirSync(stateDir, { recursive: true }) } catch {}
  }

  const appendJsonl = (obj) => {
    try {
      ensureDir()
      fs.appendFileSync(eventsPath, `${JSON.stringify(obj)}\n`, { encoding: 'utf8' })
    } catch {}
  }

  const nowUtc = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')

  const escapeSqlLiteral = (s) => String(s ?? '').replace(/'/g, "''")

  appendJsonl({ event: 'plugin.loaded', time_utc: nowUtc(), cwd: directory })

  if (!hasSetup()) {
    try {
      await client.tui.showToast({
        directory,
        title: 'agent-memory-systems-postgres',
        message: 'Optional setup not completed. Run bootstrap to enable pgpass/pgvector/Ollama and record setup.json.',
        variant: 'warning',
        duration: 8000,
      })
    } catch {}
  }

  const tryPsqlStore = async ({ sessionID }) => {
    try {
      const pgHost = process.env.PGHOST ?? 'localhost'
      const pgPort = process.env.PGPORT ?? '5432'
      const pgDb = process.env.PGDATABASE ?? 'agent_memory'
      const pgUser = process.env.PGUSER ?? 'postgres'
      const time = nowUtc()
      const sid = escapeSqlLiteral(sessionID)
      const cwd = escapeSqlLiteral(directory)
      const t = escapeSqlLiteral(time)
      const sql = `SELECT store_memory('episodic','compaction',ARRAY['compaction','opencode'],'OpenCode Compaction ${sid} ${t}','session_id=${sid} cwd=${cwd} time_utc=${t}',jsonb_build_object('session_id','${sid}','cwd','${cwd}','time_utc','${t}','source','opencode-plugin'),'opencode-plugin','${sid}',7.0);`
      await $`psql -w -h ${pgHost} -p ${pgPort} -U ${pgUser} -d ${pgDb} -v ON_ERROR_STOP=1 -c ${sql}`.quiet()
    } catch {}
  }

  return {
    'experimental.session.compacting': async (input, output) => {
      const sessionID = input.sessionID
      appendJsonl({ event: 'session.compacting', time_utc: nowUtc(), session_id: sessionID, cwd: directory })

      if (!hasSetup()) {
        output.context.push(`## Setup Missing (agent-memory-systems-postgres)
- Ask the user if they want to enable optional components: pgpass, pgvector, local embeddings (Ollama)
- Record the choice by running the bootstrap script in the skill directory (writes setup.json)
- Recommended: install all optional components, then fix any failures reported
`)
      }

      output.context.push(`## Memory System (agent-memory-systems-postgres)
- Use store_memory(...) after solving non-obvious problems
- Compaction is logged (local jsonl + optional Postgres write)
`)

      await tryPsqlStore({ sessionID })
    },
    event: async ({ event }) => {
      if (event.type === 'session.compacted') {
        appendJsonl({ event: 'session.compacted', time_utc: nowUtc(), session_id: event.properties.sessionID, cwd: directory })
        try {
          await client.app.log({ body: { service: 'agent-memory-systems-postgres', level: 'info', message: 'Session compacted (logged)' } })
        } catch {}
      }
    },
  }
}
