ALTER STREAM cpu_metrics
    ADD COLUMN frequency_hz float64 AFTER usage_percent;
