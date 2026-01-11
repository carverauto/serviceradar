-- DEPRECATED: This migration is now a no-op.
-- The otel_metrics table and continuous aggregations are now created in tenant schemas.
-- See: elixir/serviceradar_core/priv/repo/tenant_migrations/

-- Original functionality (now in tenant migrations):
-- - Add unit column to otel_metrics
-- - Create otel_metrics_hourly_stats continuous aggregation
