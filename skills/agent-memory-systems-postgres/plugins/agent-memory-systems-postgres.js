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

  const defaultPgUser = (() => {
    try { return os.userInfo().username } catch { return 'postgres' }
  })()

  const hasSetup = () => {
    try { return fs.existsSync(setupPath) } catch { return false }
  }

  const ensureDir = () => {
    try { fs.mkdirSync(stateDir, { recursive: true }) } catch {}
  }

  const readSetup = () => {
    try {
      const raw = fs.readFileSync(setupPath, { encoding: 'utf8' })
      return JSON.parse(raw)
    } catch {
      return null
    }
  }

  const appendJsonl = (obj) => {
    try {
      ensureDir()
      fs.appendFileSync(eventsPath, `${JSON.stringify(obj)}\n`, { encoding: 'utf8' })
    } catch {}
  }

  const nowUtc = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')

  const escapeSqlLiteral = (s) => String(s ?? '').replace(/'/g, "''")

  const getPgConfig = () => {
    return {
      host: process.env.PGHOST ?? 'localhost',
      port: process.env.PGPORT ?? '5432',
      db: process.env.PGDATABASE ?? 'agent_memory',
      user: process.env.PGUSER ?? defaultPgUser,
    }
  }

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

  const tryVerifySetup = async () => {
    const setup = readSetup()
    const selected = setup?.selected
    if (!selected) return

    const pg = getPgConfig()
    const time = nowUtc()
    const results = {
      pgvector: null,
      ollama: null,
    }

    if (selected.pgvector) {
      try {
        await $`psql -w -h ${pg.host} -p ${pg.port} -U ${pg.user} -d ${pg.db} -v ON_ERROR_STOP=1 -c "SELECT 1 FROM pg_extension WHERE extname='vector';"`.quiet()
        results.pgvector = true
      } catch {
        results.pgvector = false
        try {
          await client.tui.showToast({
            directory,
            title: 'agent-memory-systems-postgres',
            message: 'Setup selected pgvector=true but extension "vector" is not available (or psql auth failed).',
            variant: 'warning',
            duration: 8000,
          })
        } catch {}
      }
    }

    if (selected.ollama) {
      try {
        await $`curl -fsS http://localhost:11434/api/tags`.quiet()
        results.ollama = true
      } catch {
        results.ollama = false
        try {
          await client.tui.showToast({
            directory,
            title: 'agent-memory-systems-postgres',
            message: 'Setup selected ollama=true but http://localhost:11434 is not reachable.',
            variant: 'warning',
            duration: 8000,
          })
        } catch {}
      }
    }

    appendJsonl({ event: 'setup.verified', time_utc: time, selected, results })
  }

  try { await tryVerifySetup() } catch {}

  const tryPsqlStore = async ({ sessionID }) => {
    try {
      const pg = getPgConfig()
      const time = nowUtc()
      const sid = escapeSqlLiteral(sessionID)
      const cwd = escapeSqlLiteral(directory)
      const t = escapeSqlLiteral(time)
      const sql = `SELECT store_memory('episodic','compaction',ARRAY['compaction','opencode'],'OpenCode Compaction ${sid} ${t}','session_id=${sid} cwd=${cwd} time_utc=${t}',jsonb_build_object('session_id','${sid}','cwd','${cwd}','time_utc','${t}','source','opencode-plugin'),'opencode-plugin','${sid}',7.0);`
      await $`psql -w -h ${pg.host} -p ${pg.port} -U ${pg.user} -d ${pg.db} -v ON_ERROR_STOP=1 -c ${sql}`.quiet()
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
