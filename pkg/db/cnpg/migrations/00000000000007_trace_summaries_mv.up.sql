-- DEPRECATED: This migration is now a no-op.
-- The otel_trace_summaries materialized view is now created in tenant schemas.
-- See: elixir/serviceradar_core/priv/repo/tenant_migrations/

-- Original functionality (now in tenant migrations):
-- - Create otel_trace_summaries materialized view aggregating trace data by trace_id
