-- DEPRECATED: This migration is now a no-op.
-- Observability continuous aggregations are now created in tenant schemas.
-- See: elixir/serviceradar_core/priv/repo/tenant_migrations/

-- Original functionality (now in tenant migrations):
-- - logs_severity_stats_5m CAGG
-- - traces_stats_5m CAGG
-- - services_availability_5m CAGG
