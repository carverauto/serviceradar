# SNMP Collector (embedded in serviceradar-agent)

## Key Components

**Collector**: Handles SNMP polling for a single target device

Manages SNMP connection
Polls configured OIDs (GET) and walks configured subtrees (WALK)
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
  "enabled": true,
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
      "service_name": "serviceradar-agent",
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

### Walk Mode

An OID entry defaults to a single SNMP GET of one scalar instance. Tables cannot be
collected that way - their row indices are not known ahead of time and shift between
polls - so an entry can instead walk the subtree rooted at its OID:

```json
{
  "oid": ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2",
  "name": "cppmServiceName",
  "type": "string",
  "mode": "walk",
  "max_rows": 500,
  "walk_timeout": "15s"
}
```

- **mode**: `get` (default, also used when omitted) or `walk`. Omitting the field
  keeps the exact behavior an existing config already has. Control-plane
  profiles send this as proto `SNMPOIDConfig.mode`; a walk configured only in
  the UI/DB does nothing until that field is compiled onto the agent.
- **max_rows**: caps the rows a single walk collects. Defaults to 5000.
- **walk_timeout**: wall-clock bound for a single walk. Defaults to 30s.

The walk uses GETBULK on v2c/v3 and GETNEXT on v1, which has no GETBULK PDU. When a
walk hits either bound it stops there and the rows collected so far are still
reported, with a warning naming the bound - a runaway table cannot stall the poll
loop.

Each discovered row becomes its own data point named `<name>::index:<oid-suffix>`
(for example `cppmServiceName::index:3`), reusing the existing `name::label` series
identity convention. The bare index is also carried on the data point as
`oid_index`. Because the index is the OID suffix below the walked root, rows from
parallel column subtrees that share an index are the same table row, which is what
makes columns like `cppmServiceName`, `cppmServicePort` and `cppmServiceCount`
joinable after collection.

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
- **service_name**: Service name for telemetry - defaults to "serviceradar-agent"
- **batch_timeout**: Batch timeout for log export - defaults to "5s"
- **insecure**: Use insecure connection - defaults to false

The logger configuration is optional. If not provided, the checker will use default settings with info-level logging to stdout.
