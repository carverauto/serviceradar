-- Enable pg_trgm extension for efficient ILIKE queries with trigram indexes
-- This allows GIN indexes to accelerate case-insensitive pattern matching
-- including queries with leading wildcards (e.g., '%server%')
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Create GIN trigram indexes on frequently searched text columns in unified_devices
-- These indexes enable fast ILIKE/LIKE queries without requiring sequential scans

-- Index on hostname - primary search target for device lookups
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unified_devices_hostname_trgm
    ON unified_devices USING gin (hostname gin_trgm_ops);

-- Index on ip - commonly used for searching devices by IP pattern
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unified_devices_ip_trgm
    ON unified_devices USING gin (ip gin_trgm_ops);
