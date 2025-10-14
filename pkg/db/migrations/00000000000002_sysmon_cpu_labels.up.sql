-- Migration: Add sysmon CPU label/cluster columns and indexes

ALTER STREAM cpu_metrics
  ADD COLUMN IF NOT EXISTS label string AFTER frequency_hz;

ALTER STREAM cpu_metrics
  ADD COLUMN IF NOT EXISTS cluster string AFTER label;

ALTER STREAM cpu_metrics
  ADD INDEX IF NOT EXISTS idx_cpu_metrics_cluster cluster TYPE bloom_filter GRANULARITY 1;

ALTER STREAM cpu_metrics
  ADD INDEX IF NOT EXISTS idx_cpu_metrics_label label TYPE bloom_filter GRANULARITY 1;

