# ServiceRadar Proton Adapter Implementation Guide

## Overview

The serviceradar-proton-adapter is a Rust-based replacement for the existing Go-based poller in the ServiceRadar monitoring system. It's designed to:

1. Receive metrics from ServiceRadar agents and checkers via gRPC
2. Process and store them in Timeplus Proton (a time-series database)
3. Optionally forward metrics to the existing ServiceRadar core service
4. Support direct agent polling similar to the original poller functionality

## Implementation Details

### Fixed Issues

1. **Module Organization**: Properly structured Rust modules for processor, models, and processors
2. **Proto Definitions**: Fixed the gRPC/protobuf integration using tonic
3. **Agent Polling**: Added functionality to actively poll agents for metrics
4. **Health Checks**: Implemented health checks for ensuring agent availability
5. **Proton Integration**: Added SQL query formatting for Proton time-series database

### Key Components

1. **ProtonAdapter**: The main component implementing the gRPC PollerService and managing processors
2. **DataProcessor Trait**: An abstraction for handling different types of metrics (sysmon, rperf)
3. **Specific Processors**:
    - SysmonProcessor: For handling system metrics (CPU, memory, disk)
    - RperfProcessor: For handling network performance metrics
4. **Config**: JSON-based configuration similar to other ServiceRadar components

## Building and Running

### Prerequisites

1. Rust 1.56+ with Cargo
2. A running Proton instance
3. ServiceRadar agents and checkers

### Building

1. Update your `Cargo.toml` to include all necessary dependencies
2. Place the fixed files in the appropriate directory structure:
    - src/
        - main.rs
        - adapter.rs
        - processor.rs
        - models/
            - mod.rs
            - types.rs
        - processors/
            - mod.rs
            - sysmon.rs
            - rperf.rs
        - proto/
            - monitoring.proto

3. Build the project:
   ```bash
   cargo build --release
   ```

### Running

1. Create a configuration file (e.g., `proton-adapter.json`) based on the provided example
2. Run the adapter:
   ```bash
   ./target/release/serviceradar-proton-adapter --config-file=proton-adapter.json
   ```

## Usage Scenarios

### 1. Passive Mode (Receiving Metrics Only)

Configure with an empty `agents` section to only receive metrics pushed by the original poller:

```json
{
  "proton_url": "http://localhost:3000",
  "listen_addr": "0.0.0.0:50053",
  "core_address": "http://localhost:50052",
  "forward_to_core": true,
  "poll_interval": 30,
  "agents": {}
}
```

### 2. Active Polling Mode

Configure with agent definitions to actively poll metrics:

```json
{
  "proton_url": "http://localhost:3000",
  "listen_addr": "0.0.0.0:50053",
  "core_address": null,
  "forward_to_core": false,
  "poll_interval": 30,
  "agents": {
    "local-agent": {
      "address": "localhost:50051",
      "checks": [
        {
          "service_type": "grpc",
          "service_name": "sysmon",
          "details": "localhost:50060"
        }
      ]
    }
  }
}
```

### 3. Hybrid Mode (Data Collection + Forwarding)

Configure with both agent polling and forwarding to support gradual migration:

```json
{
  "proton_url": "http://localhost:3000",
  "listen_addr": "0.0.0.0:50053",
  "core_address": "http://localhost:50052",
  "forward_to_core": true,
  "poll_interval": 30,
  "agents": {
    "local-agent": {
      "address": "localhost:50051",
      "checks": [
        {
          "service_type": "grpc",
          "service_name": "sysmon",
          "details": "localhost:50060"
        }
      ]
    }
  }
}
```

## Extending with New Processors

To add support for new metric types:

1. Create a new processor in `src/processors/` that implements the `DataProcessor` trait
2. Register it in `src/adapter.rs` with `adapter.register_processor(Box::new(YourProcessor {}));`
3. Implement the necessary Proton stream creation and data processing logic

## Querying Data in Proton

After running the adapter, you can query the collected metrics in Proton:

```sql
-- CPU usage per core
SELECT poller_id, core_id, avg_usage FROM cpu_usage_1m 
WHERE window_start > now() - interval 1 hour
ORDER BY window_start DESC;

-- Disk usage trends
SELECT poller_id, mount_point, usage_percent FROM disk_usage_1m
WHERE window_start > now() - interval 1 day
ORDER BY window_start DESC;

-- Network performance
SELECT poller_id, target, avg_bits_per_second, success_rate FROM rperf_1m
WHERE window_start > now() - interval 6 hour
ORDER BY window_start DESC;
```

## Production Considerations

For large-scale deployments (100,000+ hosts):

1. **Proton Clustering**: Configure Proton in a clustered setup
2. **Connection Pooling**: Increase the connection pool size for the HTTP client
3. **Error Handling**: Implement retries and circuit breaking for resilience
4. **Metrics**: Add monitoring for the adapter itself

## Next Steps

1. Add proper gRPC health checking using the standard protocol
2. Implement more sophisticated error handling and retry logic
3. Add metrics collection for the adapter itself
4. Add more processors for other ServiceRadar checkers
5. Add TLS/mTLS support for secure gRPC connections