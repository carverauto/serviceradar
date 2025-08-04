-- =================================================================
-- == Rollback OTEL Logs Stream Migration
-- =================================================================
-- Remove logs table and related indexes

-- Drop the logs table
DROP STREAM IF EXISTS logs;