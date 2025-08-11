# OpenTelemetry (OTel) Configuration for Poller

The ServiceRadar poller supports OpenTelemetry (OTel) for exporting logs to external observability platforms. This document explains how to configure OTel in the poller.

## Configuration

OTel configuration is part of the `logging` section in the poller configuration file. Here's the structure:

```json
{
  "logging": {
    "level": "info",           // Log level: debug, info, warn, error
    "debug": false,            // Enable debug mode
    "output": "stdout",        // Output: stdout or stderr
    "time_format": "",         // Optional time format (defaults to RFC3339)
    "otel": {
      "enabled": true,         // Enable/disable OTel
      "endpoint": "localhost:4317",  // OTel collector endpoint
      "headers": {             // Optional headers for authentication
        "Authorization": "Bearer <token>"
      },
      "service_name": "serviceradar-poller",  // Service name in OTel
      "batch_timeout": "5s",   // Batch timeout for log export
      "insecure": false,       // Use insecure connection (for development)
      "cert_file": "/path/to/cert.pem",  // Optional client certificate
      "ca_file": "/path/to/ca.pem"       // Optional CA certificate
    }
  }
}
```

## Environment Variables

The following environment variables can be used to configure OTel (these are read as defaults):

- `OTEL_LOGS_ENABLED`: Enable/disable OTel logs (true/false)
- `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`: OTel collector endpoint
- `OTEL_EXPORTER_OTLP_LOGS_HEADERS`: Headers in format "key1=value1,key2=value2"
- `OTEL_SERVICE_NAME`: Service name for OTel
- `OTEL_EXPORTER_OTLP_LOGS_TIMEOUT`: Batch timeout (e.g., "5s", "1m")
- `OTEL_EXPORTER_OTLP_LOGS_INSECURE`: Use insecure connection (true/false)

## Example Configurations

### Basic Configuration (Insecure for Development)

```json
{
  "logging": {
    "level": "info",
    "otel": {
      "enabled": true,
      "endpoint": "localhost:4317",
      "service_name": "serviceradar-poller-dev",
      "insecure": true
    }
  }
}
```

### Production Configuration with Authentication

```json
{
  "logging": {
    "level": "info",
    "otel": {
      "enabled": true,
      "endpoint": "otel-collector.example.com:4317",
      "headers": {
        "Authorization": "Bearer your-api-key-here"
      },
      "service_name": "serviceradar-poller-prod",
      "batch_timeout": "10s",
      "insecure": false,
      "cert_file": "/etc/serviceradar/certs/otel-client.pem",
      "ca_file": "/etc/serviceradar/certs/otel-ca.pem"
    }
  }
}
```

### Minimal Configuration (OTel Disabled)

```json
{
  "logging": {
    "level": "info",
    "otel": {
      "enabled": false
    }
  }
}
```

## How It Works

When OTel is enabled:

1. The poller creates an OTel exporter that connects to the specified endpoint
2. All logs are sent to both the local output (stdout/stderr) and the OTel collector
3. Logs are batched and sent periodically based on the `batch_timeout` setting
4. The service name is included with all logs for easy filtering in your observability platform

## Troubleshooting

1. **Connection Issues**: If you see connection errors, ensure:
   - The OTel collector is running and accessible
   - The endpoint URL is correct (including port)
   - Firewall rules allow the connection
   - For secure connections, certificates are valid

2. **Authentication Failures**: Check that:
   - Headers are correctly formatted
   - API keys/tokens are valid
   - Certificate paths are correct and files are readable

3. **No Logs Appearing**: Verify that:
   - `enabled` is set to `true`
   - The log level is appropriate for the logs you expect
   - The OTel collector is configured to receive logs

## Integration with Sync Service

The sync service uses the same OTel configuration structure. You can use similar configuration for both services to have unified observability.

## ServiceRadar Trace Processing

ServiceRadar automatically processes OpenTelemetry traces through a sophisticated pipeline:

1. **Ingestion**: Raw OTEL traces are stored in the `otel_traces` stream
2. **Enrichment**: Materialized views calculate span durations and detect root spans
3. **Aggregation**: Trace-level summaries are pre-calculated for fast querying
4. **Querying**: Use SRQL or SQL to query enriched trace data

### Available Streams for Analysis

- `otel_traces` - Raw trace data from collectors
- `otel_spans_enriched` - Enriched spans with calculated durations and root detection
- `otel_trace_summaries_final` - Pre-aggregated trace summaries (recommended for dashboards)
- `otel_root_spans` - Root spans only for service-level analysis

### Example Query Integration

```go
// Query slow traces using SRQL
slowTraces := "show otel_trace_summaries where duration_ms > 1000 and timestamp >= now() - interval 1 hour"

// Query specific trace details
traceDetails := "show otel_spans_enriched where trace_id = 'abc123' order by start_time_unix_nano"
```

This integration allows complete request tracing from poller → agent → core with proper duration calculations and service correlation.