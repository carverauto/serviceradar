-- Ensure spire role can read OTEL/log tables used by core telemetry tailers.

GRANT USAGE ON SCHEMA public TO spire;
GRANT SELECT ON TABLE logs TO spire;
GRANT SELECT ON TABLE otel_metrics TO spire;
GRANT SELECT ON TABLE otel_traces TO spire;
