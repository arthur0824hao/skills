BEGIN;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'memory_type') THEN
    CREATE TYPE memory_type AS ENUM ('working','episodic','semantic','procedural');
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Optional: pgvector for semantic similarity search.
-- This is non-fatal if the extension is not installed on the server.
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
  EXCEPTION WHEN OTHERS THEN
    -- pgvector not available; continue without semantic vector search.
    NULL;
  END;
END $$;

CREATE TABLE IF NOT EXISTS agent_memories (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    accessed_at TIMESTAMPTZ DEFAULT NOW(),

    memory_type memory_type NOT NULL,
    category VARCHAR(100) NOT NULL,
    subcategory VARCHAR(100),
    tags TEXT[],

    title TEXT NOT NULL,
    content TEXT NOT NULL,
    content_hash TEXT,

    metadata JSONB DEFAULT '{}',

    agent_id VARCHAR(100),
    session_id VARCHAR(100),
    user_id VARCHAR(100),

    importance_score NUMERIC(5,2) DEFAULT 5.00
        CHECK (importance_score BETWEEN 0 AND 10),
    access_count INTEGER DEFAULT 0,
    relevance_decay NUMERIC(5,4) DEFAULT 1.0000,

    search_vector tsvector,
    deleted_at TIMESTAMPTZ
);

-- If pgvector is available, add an embedding column.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_name = 'agent_memories' AND column_name = 'embedding'
    ) THEN
      -- Use variable-dimension vectors (vector without size) for compatibility
      -- across different local embedding models. This cannot be indexed.
      ALTER TABLE agent_memories ADD COLUMN embedding vector;
    END IF;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS memory_links (
    source_id BIGINT REFERENCES agent_memories(id),
    target_id BIGINT REFERENCES agent_memories(id),
    link_type VARCHAR(50) NOT NULL,
    strength NUMERIC(3,2) DEFAULT 1.0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (source_id, target_id, link_type)
);

CREATE TABLE IF NOT EXISTS working_memory (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(100) NOT NULL,
    agent_id VARCHAR(100) NOT NULL,
    sequence_num INTEGER NOT NULL,
    role VARCHAR(20) NOT NULL,
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '24 hours',
    UNIQUE(session_id, sequence_num)
);

CREATE INDEX IF NOT EXISTS idx_am_type       ON agent_memories(memory_type)                          WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_category   ON agent_memories(category)                             WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_tags       ON agent_memories USING GIN(tags)                       WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_fts        ON agent_memories USING GIN(search_vector)              WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_agent      ON agent_memories(agent_id, session_id)                 WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_importance ON agent_memories(importance_score DESC, accessed_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_hash       ON agent_memories(content_hash)                         WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_meta       ON agent_memories USING GIN(metadata)                   WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_trgm_title ON agent_memories USING GIN(title gin_trgm_ops)        WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_am_trgm_body  ON agent_memories USING GIN(content gin_trgm_ops)      WHERE deleted_at IS NULL;

-- NOTE: No vector index is created since the embedding column is variable-dimension.
CREATE INDEX IF NOT EXISTS idx_ml_src        ON memory_links(source_id);
CREATE INDEX IF NOT EXISTS idx_ml_tgt        ON memory_links(target_id);
CREATE INDEX IF NOT EXISTS idx_wm_session    ON working_memory(session_id, sequence_num);

CREATE OR REPLACE FUNCTION update_memory_metadata()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', COALESCE(NEW.title,'')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.content,'')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.category,'')), 'C') ||
        setweight(to_tsvector('english', COALESCE(array_to_string(NEW.tags,' '),'')), 'D');

    NEW.content_hash := md5(NEW.content);
    NEW.updated_at   := NOW();

    IF TG_OP = 'INSERT' THEN
        NEW.relevance_decay := 1.0000;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trig_update_memory_metadata ON agent_memories;
CREATE TRIGGER trig_update_memory_metadata
    BEFORE INSERT OR UPDATE ON agent_memories
    FOR EACH ROW EXECUTE FUNCTION update_memory_metadata();

CREATE OR REPLACE FUNCTION validate_memory_type()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.memory_type = 'working' AND NEW.session_id IS NULL THEN
        RAISE EXCEPTION 'Working memory requires session_id';
    END IF;
    IF NEW.memory_type = 'procedural' AND NEW.importance_score < 7.0 THEN
        RAISE EXCEPTION 'Procedural memory must have importance >= 7.0';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trig_validate_memory_type ON agent_memories;
CREATE TRIGGER trig_validate_memory_type
    BEFORE INSERT OR UPDATE ON agent_memories
    FOR EACH ROW EXECUTE FUNCTION validate_memory_type();

CREATE OR REPLACE FUNCTION store_memory(
    p_type       memory_type,
    p_category   VARCHAR,
    p_tags       TEXT[],
    p_title      TEXT,
    p_content    TEXT,
    p_metadata   JSONB    DEFAULT '{}',
    p_agent_id   VARCHAR  DEFAULT NULL,
    p_session_id VARCHAR  DEFAULT NULL,
    p_importance NUMERIC  DEFAULT 5.0
) RETURNS BIGINT AS $$
DECLARE
    v_id   BIGINT;
    v_hash TEXT := md5(p_content);
BEGIN
    SELECT id INTO v_id
    FROM agent_memories
    WHERE content_hash = v_hash
      AND memory_type  = p_type
      AND category     = p_category
      AND deleted_at IS NULL
    LIMIT 1;

    IF v_id IS NOT NULL THEN
        UPDATE agent_memories SET
            accessed_at      = NOW(),
            access_count     = access_count + 1,
            importance_score = LEAST(10.0, importance_score + 0.5),
            tags             = array(SELECT DISTINCT unnest(tags || p_tags))
        WHERE id = v_id;
        RETURN v_id;
    END IF;

    INSERT INTO agent_memories
        (memory_type, category, tags, title, content, metadata, agent_id, session_id, importance_score)
    VALUES
        (p_type, p_category, p_tags, p_title, p_content, p_metadata, p_agent_id, p_session_id, p_importance)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION search_memories(
    p_query          TEXT,
    p_memory_types   memory_type[] DEFAULT NULL,
    p_categories     VARCHAR[]     DEFAULT NULL,
    p_tags           TEXT[]        DEFAULT NULL,
    p_agent_id       VARCHAR       DEFAULT NULL,
    p_min_importance NUMERIC       DEFAULT 0.0,
    p_limit          INTEGER       DEFAULT 10
) RETURNS TABLE(
    id               BIGINT,
    memory_type      memory_type,
    category         VARCHAR,
    title            TEXT,
    content          TEXT,
    importance_score NUMERIC,
    relevance_score  NUMERIC,
    match_type       TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH
    fts_query AS (
        SELECT plainto_tsquery('english', p_query) AS q
    ),
    ranked AS (
        SELECT
            m.id, m.memory_type, m.category, m.title, m.content,
            m.importance_score, m.relevance_decay,
            GREATEST(
                COALESCE(ts_rank(m.search_vector, fq.q), 0) * 10,
                COALESCE(similarity(m.title,   p_query), 0) * 5,
                COALESCE(similarity(m.content, p_query), 0) * 3
            ) AS text_score,
            EXTRACT(EPOCH FROM (NOW() - m.accessed_at)) / 86400.0 AS days_ago,
            CASE
                WHEN m.search_vector @@ fq.q           THEN 'fulltext'
                WHEN similarity(m.title,   p_query) > 0.3 THEN 'trigram_title'
                WHEN similarity(m.content, p_query) > 0.2 THEN 'trigram_content'
                ELSE 'metadata'
            END AS match_type
        FROM agent_memories m
        CROSS JOIN fts_query fq
        WHERE m.deleted_at IS NULL
          AND (p_memory_types IS NULL OR m.memory_type = ANY(p_memory_types))
          AND (p_categories   IS NULL OR m.category    = ANY(p_categories))
          AND (p_tags         IS NULL OR m.tags       && p_tags)
          AND (p_agent_id     IS NULL OR m.agent_id    = p_agent_id)
          AND m.importance_score >= p_min_importance
          AND (
              m.search_vector @@ fq.q
              OR similarity(m.title,   p_query) > 0.1
              OR similarity(m.content, p_query) > 0.05
              OR (p_tags IS NOT NULL AND m.tags && p_tags)
          )
    )
    SELECT r.id, r.memory_type, r.category, r.title, r.content,
           r.importance_score,
           (r.text_score * r.relevance_decay
            * (1.0 / (1.0 + r.days_ago * 0.01))
            * (r.importance_score / 10.0))::NUMERIC AS relevance_score,
           r.match_type
    FROM ranked r
    ORDER BY relevance_score DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Semantic vector search (requires pgvector + embeddings populated).
-- NOTE: This does not generate embeddings. You must write embeddings into agent_memories.embedding.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
    EXECUTE $sql$
CREATE OR REPLACE FUNCTION search_memories_vector(
    p_embedding      vector,
    p_embedding_dim  INTEGER       DEFAULT NULL,
    p_memory_types   memory_type[] DEFAULT NULL,
    p_categories     VARCHAR[]     DEFAULT NULL,
    p_tags           TEXT[]        DEFAULT NULL,
    p_agent_id       VARCHAR       DEFAULT NULL,
    p_min_importance NUMERIC       DEFAULT 0.0,
    p_limit          INTEGER       DEFAULT 10
) RETURNS TABLE(
    id               BIGINT,
    memory_type      memory_type,
    category         VARCHAR,
    title            TEXT,
    content          TEXT,
    importance_score NUMERIC,
    similarity       NUMERIC
) AS $fn$
BEGIN
    RETURN QUERY
    SELECT
      m.id,
      m.memory_type,
      m.category,
      m.title,
      m.content,
      m.importance_score,
      (1 - (m.embedding <=> p_embedding))::NUMERIC AS similarity
    FROM agent_memories m
    WHERE m.deleted_at IS NULL
      AND m.embedding IS NOT NULL
      AND (p_embedding_dim IS NULL OR (m.metadata->>'embedding_dim')::INT = p_embedding_dim)
      AND (p_memory_types IS NULL OR m.memory_type = ANY(p_memory_types))
      AND (p_categories   IS NULL OR m.category    = ANY(p_categories))
      AND (p_tags         IS NULL OR m.tags       && p_tags)
      AND (p_agent_id     IS NULL OR m.agent_id    = p_agent_id)
      AND m.importance_score >= p_min_importance
    ORDER BY m.embedding <=> p_embedding ASC
    LIMIT p_limit;
END;
$fn$ LANGUAGE plpgsql;
$sql$;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION apply_memory_decay() RETURNS BIGINT AS $$
DECLARE v_count BIGINT;
BEGIN
    UPDATE agent_memories
    SET relevance_decay = relevance_decay * POW(0.9999, EXTRACT(EPOCH FROM (NOW()-accessed_at))/86400)
    WHERE deleted_at IS NULL AND memory_type = 'episodic'
      AND accessed_at < NOW() - INTERVAL '1 day';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION prune_stale_memories(
    p_age_days  INTEGER DEFAULT 180,
    p_max_score NUMERIC DEFAULT 3.0,
    p_max_hits  INTEGER DEFAULT 0
) RETURNS BIGINT AS $$
DECLARE v_count BIGINT;
BEGIN
    UPDATE agent_memories SET deleted_at = NOW()
    WHERE memory_type = 'episodic'
      AND importance_score <= p_max_score
      AND access_count     <= p_max_hits
      AND created_at < NOW() - (p_age_days || ' days')::INTERVAL
      AND deleted_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION memory_health_check()
RETURNS TABLE(metric TEXT, value NUMERIC, status TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT 'total_memories'::TEXT,
           COUNT(*)::NUMERIC,
           (CASE WHEN COUNT(*) < 1000000 THEN 'healthy' ELSE 'warning' END)::TEXT
    FROM agent_memories WHERE deleted_at IS NULL
    UNION ALL
    SELECT 'avg_importance'::TEXT,
           ROUND(COALESCE(AVG(importance_score),0),2),
           (CASE WHEN COALESCE(AVG(importance_score),0) >= 5.0 THEN 'healthy' ELSE 'low' END)::TEXT
    FROM agent_memories WHERE deleted_at IS NULL
    UNION ALL
    SELECT 'stale_count'::TEXT,
           COUNT(*)::NUMERIC,
           (CASE WHEN COUNT(*) < 10000 THEN 'healthy' ELSE 'prune_needed' END)::TEXT
    FROM agent_memories
    WHERE deleted_at IS NULL AND accessed_at < NOW() - INTERVAL '90 days';
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- Task Memory Layer (minimal)
-- Inspired by Beads: graph semantics + deterministic ready-work detection.
-- No JSONL/git sync layer: PostgreSQL is the source of truth.
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_status') THEN
    CREATE TYPE task_status AS ENUM ('open','in_progress','blocked','deferred','closed','tombstone');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_link_type') THEN
    CREATE TYPE task_link_type AS ENUM (
      'blocks',
      'parent_child',
      'related',
      'discovered_from',
      'duplicates',
      'supersedes',
      'replies_to'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS agent_tasks (
  id          BIGSERIAL PRIMARY KEY,
  task_key    TEXT UNIQUE,
  title       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  status      task_status NOT NULL DEFAULT 'open',
  priority    SMALLINT NOT NULL DEFAULT 2 CHECK (priority BETWEEN 0 AND 4),
  assignee    VARCHAR(100),
  created_by  VARCHAR(100) NOT NULL DEFAULT 'unknown',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  closed_at   TIMESTAMPTZ,
  deleted_at  TIMESTAMPTZ,
  metadata    JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS task_links (
  id           BIGSERIAL PRIMARY KEY,
  from_task_id BIGINT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
  to_task_id   BIGINT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
  link_type    task_link_type NOT NULL,
  metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(from_task_id, to_task_id, link_type)
);

CREATE TABLE IF NOT EXISTS blocked_tasks_cache (
  task_id         BIGINT PRIMARY KEY REFERENCES agent_tasks(id) ON DELETE CASCADE,
  blocker_task_id BIGINT,
  reason          TEXT NOT NULL,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS task_memory_links (
  task_id    BIGINT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
  memory_id  BIGINT NOT NULL REFERENCES agent_memories(id) ON DELETE CASCADE,
  link_type  TEXT NOT NULL DEFAULT 'supports',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (task_id, memory_id, link_type)
);

CREATE INDEX IF NOT EXISTS idx_tasks_status_prio ON agent_tasks(status, priority, updated_at ASC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_assignee    ON agent_tasks(assignee) WHERE assignee IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_links_from   ON task_links(from_task_id);
CREATE INDEX IF NOT EXISTS idx_task_links_to     ON task_links(to_task_id);
CREATE INDEX IF NOT EXISTS idx_task_links_type   ON task_links(link_type);

CREATE OR REPLACE FUNCTION touch_task_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  IF NEW.status = 'closed' AND (OLD.status IS DISTINCT FROM 'closed') THEN
    NEW.closed_at := NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tasks_touch ON agent_tasks;
CREATE TRIGGER trg_tasks_touch
BEFORE UPDATE ON agent_tasks
FOR EACH ROW EXECUTE FUNCTION touch_task_updated_at();

CREATE OR REPLACE FUNCTION rebuild_blocked_tasks_cache()
RETURNS BIGINT AS $$
DECLARE v_count BIGINT;
BEGIN
  TRUNCATE blocked_tasks_cache;

  WITH RECURSIVE
  direct AS (
    SELECT
      l.to_task_id AS task_id,
      l.from_task_id AS blocker_id,
      ARRAY[l.to_task_id] AS path,
      1 AS depth
    FROM task_links l
    JOIN agent_tasks blocker ON blocker.id = l.from_task_id
    JOIN agent_tasks target  ON target.id  = l.to_task_id
    WHERE l.link_type = 'blocks'
      AND blocker.deleted_at IS NULL
      AND blocker.status NOT IN ('closed','tombstone')
      AND target.deleted_at IS NULL
      AND target.status NOT IN ('closed','tombstone')
  ),
  prop AS (
    SELECT task_id, blocker_id, path, depth
    FROM direct
    UNION ALL
    SELECT
      l.to_task_id,
      p.blocker_id,
      p.path || l.to_task_id,
      p.depth + 1
    FROM task_links l
    JOIN prop p ON p.task_id = l.from_task_id
    JOIN agent_tasks child ON child.id = l.to_task_id
    WHERE l.link_type = 'parent_child'
      AND child.deleted_at IS NULL
      AND child.status NOT IN ('closed','tombstone')
      AND p.depth < 50
      AND NOT (l.to_task_id = ANY(p.path))
  )
  INSERT INTO blocked_tasks_cache(task_id, blocker_task_id, reason, updated_at)
  SELECT DISTINCT ON (task_id)
    task_id,
    blocker_id,
    ('blocked_by:' || blocker_id::text),
    NOW()
  FROM prop
  ORDER BY task_id, blocker_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_rebuild_blocked_cache()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM rebuild_blocked_tasks_cache();
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_rebuild_blocked_cache_on_boundary()
RETURNS TRIGGER AS $$
BEGIN
  -- Only rebuild when a task crosses the "can block" boundary, or is soft-deleted/restored.
  -- This avoids rebuilding on routine status changes like open -> in_progress (claiming work),
  -- which can conflict with statements that read from blocked_tasks_cache.
  IF (OLD.deleted_at IS DISTINCT FROM NEW.deleted_at)
     OR ((OLD.status IN ('closed','tombstone')) IS DISTINCT FROM (NEW.status IN ('closed','tombstone')))
  THEN
    PERFORM rebuild_blocked_tasks_cache();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_rebuild_on_task_update ON agent_tasks;
CREATE TRIGGER trg_rebuild_on_task_update
AFTER UPDATE OF status, deleted_at ON agent_tasks
FOR EACH ROW EXECUTE FUNCTION trg_rebuild_blocked_cache_on_boundary();

DROP TRIGGER IF EXISTS trg_rebuild_on_task_insert ON agent_tasks;

DROP TRIGGER IF EXISTS trg_rebuild_on_task_links_change ON task_links;
CREATE TRIGGER trg_rebuild_on_task_links_change
AFTER INSERT OR DELETE OR UPDATE OF link_type, from_task_id, to_task_id ON task_links
FOR EACH STATEMENT EXECUTE FUNCTION trg_rebuild_blocked_cache();

CREATE OR REPLACE FUNCTION claim_task(p_task_id BIGINT, p_assignee TEXT)
RETURNS BOOLEAN AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  WITH cte AS (
    UPDATE agent_tasks t
    SET assignee = p_assignee,
        status = 'in_progress'
    WHERE t.id = p_task_id
      AND t.deleted_at IS NULL
      AND t.status = 'open'
      AND t.assignee IS NULL
      AND NOT EXISTS (SELECT 1 FROM blocked_tasks_cache b WHERE b.task_id = t.id)
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM cte) INTO v_ok;
  RETURN v_ok;
END;
$$ LANGUAGE plpgsql;

COMMIT;
