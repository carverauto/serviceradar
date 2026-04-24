-- Migration: Add BGP AS Path and Communities to netflow_metrics table
-- Date: 2026-02-15
-- Description: Adds BGP routing visibility fields to flow records

-- Add AS path column (array of AS numbers in routing sequence)
ALTER TABLE netflow_metrics
ADD COLUMN IF NOT EXISTS as_path INTEGER[] DEFAULT NULL;

-- Add BGP communities column (array of 32-bit community values)
ALTER TABLE netflow_metrics
ADD COLUMN IF NOT EXISTS bgp_communities INTEGER[] DEFAULT NULL;

-- Create GIN index for AS path queries (contains operator)
CREATE INDEX IF NOT EXISTS idx_netflow_metrics_as_path
ON netflow_metrics USING GIN (as_path);

-- Create GIN index for BGP communities queries (contains operator)
CREATE INDEX IF NOT EXISTS idx_netflow_metrics_bgp_communities
ON netflow_metrics USING GIN (bgp_communities);

-- Add comments for documentation
COMMENT ON COLUMN netflow_metrics.as_path IS
'BGP AS path sequence (source AS → intermediate AS → destination AS). Partial path constructed from available IPFIX fields.';

COMMENT ON COLUMN netflow_metrics.bgp_communities IS
'BGP community values in 32-bit format (high 16 bits = AS number, low 16 bits = value). Standard communities per RFC 1997.';

-- Example queries enabled by these indexes:
-- Find flows traversing specific AS:
--   SELECT * FROM netflow_metrics WHERE as_path @> ARRAY[64512];
--
-- Find flows with specific BGP community:
--   SELECT * FROM netflow_metrics WHERE bgp_communities @> ARRAY[4259840100];
--
-- Count flows by AS:
--   SELECT unnest(as_path) AS asn, COUNT(*)
--   FROM netflow_metrics
--   WHERE as_path IS NOT NULL
--   GROUP BY asn
--   ORDER BY COUNT(*) DESC;
