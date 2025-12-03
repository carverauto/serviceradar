-- Remove trigram indexes first
DROP INDEX CONCURRENTLY IF EXISTS idx_unified_devices_hostname_trgm;
DROP INDEX CONCURRENTLY IF EXISTS idx_unified_devices_ip_trgm;

-- Remove the pg_trgm extension
DROP EXTENSION IF EXISTS pg_trgm;
