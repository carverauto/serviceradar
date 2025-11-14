-- Migration: Add sysmon CPU label/cluster columns and indexes

ALTER STREAM cpu_metrics
  ADD COLUMN IF NOT EXISTS label string;

ALTER STREAM cpu_metrics
  ADD COLUMN IF NOT EXISTS cluster string;

ALTER STREAM cpu_metrics
  ADD INDEX IF NOT EXISTS idx_cpu_metrics_cluster cluster TYPE bloom_filter GRANULARITY 1;

ALTER STREAM cpu_metrics
  ADD INDEX IF NOT EXISTS idx_cpu_metrics_label label TYPE bloom_filter GRANULARITY 1;
