-- Infrastructure Database Initialization
-- This script runs automatically when the postgres container starts
-- For ParadeDB (PostgreSQL 17+ with pg_search and pgvector bundled)
--
-- NOTE: This only initializes shared extensions and utilities.
-- Application-specific tables should be initialized by each service:
--   - incident_crawler: crawler tables
--   - incident_pipeline: documents, embeddings tables
--   - polaris/analysis-interface: conversations, messages, knowledge tables

-- ============================================================================
-- EXTENSIONS
-- ============================================================================
-- ParadeDB auto-loads pg_search and pgvector, but we create them for compatibility
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- ============================================================================
-- SHARED UTILITY FUNCTIONS
-- ============================================================================

-- Function to update updated_at timestamp (used by multiple services)
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
