-- =================================================================
-- == Drop Complete ServiceRadar Schema
-- =================================================================
-- This drops the entire ServiceRadar database schema.
-- WARNING: This will delete ALL data!

-- Drop views first (dependency order)
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
DROP VIEW IF EXISTS otel_trace_summaries_final;
DROP VIEW IF EXISTS otel_trace_summaries_dedup;

-- Drop materialized views
DROP VIEW IF EXISTS otel_trace_summaries_mv;

-- Drop all streams
DROP STREAM IF EXISTS otel_span_attrs;
DROP STREAM IF EXISTS otel_spans_enriched;
DROP STREAM IF EXISTS otel_trace_summaries;
DROP STREAM IF EXISTS otel_traces;
DROP STREAM IF EXISTS otel_metrics;
DROP STREAM IF EXISTS process_metrics;
DROP STREAM IF EXISTS logs;
DROP STREAM IF EXISTS services;
DROP STREAM IF EXISTS network_sweeps;
DROP STREAM IF EXISTS auth_credentials;
DROP STREAM IF EXISTS snmp_status;
DROP STREAM IF EXISTS interfaces;
DROP STREAM IF EXISTS device_discoveries;
DROP STREAM IF EXISTS devices;
DROP STREAM IF EXISTS pollers;