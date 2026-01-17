-- DEPRECATED: This migration is now a no-op.
-- The otel_trace_summaries materialized view is now created in schemas.
-- See: elixir/serviceradar_core/priv/repo/migrations/

-- Original functionality (now in Ash migrations):
-- - Create otel_trace_summaries materialized view aggregating trace data by trace_id
