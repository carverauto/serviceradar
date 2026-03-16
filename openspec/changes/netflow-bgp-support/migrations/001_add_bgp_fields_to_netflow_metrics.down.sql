-- Rollback Migration: Remove BGP fields from netflow_metrics table
-- Date: 2026-02-15

-- Drop indexes first
DROP INDEX IF EXISTS idx_netflow_metrics_bgp_communities;
DROP INDEX IF EXISTS idx_netflow_metrics_as_path;

-- Drop columns
ALTER TABLE netflow_metrics DROP COLUMN IF EXISTS bgp_communities;
ALTER TABLE netflow_metrics DROP COLUMN IF EXISTS as_path;
