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
    EXECUTE $$
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
) AS $$
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
$$ LANGUAGE plpgsql;
$$;
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

COMMIT;
