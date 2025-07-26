# SNMP Poller

## Key Components

**Collector**: Handles SNMP polling for a single target device

Manages SNMP connection
Polls configured OIDs
Converts values based on data type
Supports scaling and delta calculations


**SNMPService**: Main service that manages collectors

Initializes collectors for each target
Provides status information to the agent
Manages lifecycle (start/stop)


**Aggregator**: Handles data aggregation

Stores time-series data points
Provides aggregation functions (avg, min, max)
Manages data retention

## Config

```json
{
  "node_address": "localhost:50051",
  "listen_addr": ":50052",
  "timeout": "5m",
  "logger": {
    "level": "info",
    "debug": false,
    "output": "stdout",
    "time_format": "",
    "otel": {
      "enabled": false,
      "endpoint": "",
      "headers": {},
      "service_name": "serviceradar-snmp-checker",
      "batch_timeout": "5s",
      "insecure": false
    }
  },
  "targets": [
    {
      "name": "switch1",
      "host": "192.168.1.1",
      "port": 161,
      "community": "public",
      "version": "v2c",
      "interval": "30s",
      "retries": 2,
      "max_points": 1000,
      "oids": [
        {
          "oid": ".1.3.6.1.2.1.2.2.1.10.1",
          "name": "ifInOctets_eth0",
          "type": "counter",
          "scale": 1.0,
          "delta": true
        },
        {
          "oid": ".1.3.6.1.2.1.2.2.1.16.1",
          "name": "ifOutOctets_eth0",
          "type": "counter",
          "scale": 1.0,
          "delta": true
        }
      ]
    }
  ]
}
```

### Logger Configuration

The SNMP checker supports structured logging with optional OpenTelemetry integration:

- **level**: Log level (debug, info, warn, error) - defaults to "info"
- **debug**: Enable debug logging - defaults to false
- **output**: Log output destination (stdout, stderr) - defaults to "stdout"
- **time_format**: Custom timestamp format - uses RFC3339 if empty
- **otel**: OpenTelemetry configuration for log export

### OpenTelemetry Configuration

- **enabled**: Enable OTel log export - defaults to false
- **endpoint**: OTel collector endpoint (e.g., "localhost:4317")
- **headers**: Additional headers for authentication
- **service_name**: Service name for telemetry - defaults to "serviceradar-snmp-checker"
- **batch_timeout**: Batch timeout for log export - defaults to "5s"
- **insecure**: Use insecure connection - defaults to false

The logger configuration is optional. If not provided, the checker will use default settings with info-level logging to stdout.