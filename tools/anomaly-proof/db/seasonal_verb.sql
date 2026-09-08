-- The real SRQL `profile_hour_of_week` verb SQL (build_profile_hour_of_week_query,
-- rust/srql/src/query/timeseries_metrics.rs:1112-1214), CTEs verbatim; the bind
-- placeholders are filled with the seasonal Source's literal scope/filters
-- (metric_type sysmon.cpu, metric_name cpu.usage_percent, timezone UTC) and the
-- final SELECT emits the kernel's SeasonalRow CSV columns instead of the jsonb payload.
WITH hourly AS (
  SELECT device_id AS series, bucket, avg_value::float8 AS sample_value
  FROM timeseries_metrics_hourly
  WHERE device_id IS NOT NULL AND metric_type = 'sysmon.cpu'
    AND bucket >= TIMESTAMPTZ '2023-12-01' AND bucket <= TIMESTAMPTZ '2024-04-01'
    AND metric_name = 'cpu.usage_percent'
),
local_hourly AS (
  SELECT series, bucket, sample_value,
    EXTRACT(DOW FROM timezone('UTC', bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone('UTC', bucket))::int AS hod
  FROM hourly
),
latest AS (
  SELECT DISTINCT ON (series) series, bucket, sample_value,
    EXTRACT(DOW FROM timezone('UTC', bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone('UTC', bucket))::int AS hod
  FROM hourly ORDER BY series, bucket DESC
),
mean_profile AS (
  SELECT series, dow, hod, COUNT(*)::bigint AS bucket_count,
    SUM(sample_value)::float8 AS bucket_sum, SUM(sample_value*sample_value)::float8 AS bucket_sum_sq
  FROM local_hourly GROUP BY 1,2,3
),
robust_values AS (
  SELECT h.* FROM local_hourly h JOIN latest l
    ON l.series=h.series AND l.dow=h.dow AND l.hod=h.hod WHERE h.bucket <> l.bucket
),
robust_base AS (
  SELECT series,dow,hod,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY sample_value)::float8 AS center,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY sample_value)::float8 AS p05,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY sample_value)::float8 AS p95
  FROM robust_values GROUP BY 1,2,3
),
robust_profile AS (
  SELECT b.series,b.dow,b.hod,b.center,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(v.sample_value-b.center))::float8 AS mad,
    b.p05,b.p95
  FROM robust_base b JOIN robust_values v
    ON v.series=b.series AND v.dow=b.dow AND v.hod=b.hod
  GROUP BY b.series,b.dow,b.hod,b.center,b.p05,b.p95
)
SELECT l.series, l.dow, l.hod, l.sample_value, p.bucket_count, p.bucket_sum, p.bucket_sum_sq,
  COALESCE(r.center,0)::float8, COALESCE(r.mad,0)::float8, COALESCE(r.p05,0)::float8, COALESCE(r.p95,0)::float8, 0, 1
FROM latest l
JOIN mean_profile p ON p.series=l.series AND p.dow=l.dow AND p.hod=l.hod
LEFT JOIN robust_profile r ON r.series=l.series AND r.dow=l.dow AND r.hod=l.hod
ORDER BY l.series;
