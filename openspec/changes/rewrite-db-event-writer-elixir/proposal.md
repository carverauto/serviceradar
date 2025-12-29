# Rewrite db-event-writer in Elixir

## Summary

Rewrite the Go-based `db-event-writer` service as an Elixir GenServer within the `serviceradar_core` application. This consolidates the NATS JetStream event consumer into the existing Elixir stack, eliminating migration drift issues, reducing operational complexity, and leveraging Elixir's supervision trees for reliability.

## Motivation

### Current Issues

1. **Migration Drift**: The Go `db-event-writer` binary embeds CNPG migrations that have drifted from the canonical schema in `pkg/db/cnpg/migrations/`. The embedded file is named `00000000000001_timescale_schema.up.sql` but the repo file is `00000000000001_schema.up.sql`, causing startup failures.

2. **Separate Process Management**: Running db-event-writer as a separate container adds operational overhead:
   - Separate image build/push cycle
   - Separate TLS certificate configuration
   - Separate health monitoring
   - Separate log aggregation

3. **Dual Database Stacks**: Go's `pgx` pool and Elixir's Ecto both connect to CNPG. Consolidating to Ecto simplifies connection pooling, credential management, and TLS configuration.

4. **No Hot Reload**: The Go service requires container restarts for configuration changes, while Elixir can use dynamic supervision and GenServer state updates.

### Benefits of Elixir Rewrite

1. **Unified Stack**: Single codebase, single image, single deployment for core-elx
2. **Shared Migrations**: Use Ecto migrations managed by Ash for schema evolution
3. **Broadway for NATS**: Reliable, back-pressure-aware message consumption with Broadway
4. **Supervision Trees**: Automatic restart/recovery via OTP supervisors
5. **Telemetry Integration**: Native integration with existing Elixir telemetry/metrics
6. **Hot Configuration**: GenServer state updates without restarts

## Scope

### In Scope

- Elixir GenServer that consumes NATS JetStream messages
- Broadway producer for NATS JetStream
- Ecto-based writes to CNPG hypertables
- Support for all current stream configurations (telemetry, events, sweep, netflow, etc.)
- Telemetry metrics for message processing
- Graceful shutdown with message acknowledgment

### Out of Scope

- Changes to NATS JetStream stream configuration (consumers remain compatible)
- Changes to message formats/protocols
- Migration of existing Go CNPG migrations to Ecto (leave pkg/db/cnpg as-is for other Go services)

## Technical Approach

### Architecture

```
                                 core-elx Application
┌────────────────────────────────────────────────────────────────────────────┐
│                                                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     EventWriter.Supervisor                          │   │
│  │                                                                     │   │
│  │  ┌───────────────┐   ┌───────────────┐   ┌───────────────┐         │   │
│  │  │  Broadway     │   │   Processor   │   │   Config      │         │   │
│  │  │  (NATS JS)    │──▶│   (batched)   │──▶│   Watcher     │         │   │
│  │  └───────────────┘   └───────────────┘   └───────────────┘         │   │
│  │         │                   │                                       │   │
│  │         ▼                   ▼                                       │   │
│  │  ┌───────────────────────────────────────────────────────────────┐ │   │
│  │  │                    Ecto / Repo                                 │ │   │
│  │  └───────────────────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐  │
│  │  ClusterHealth   │  │  PollOrchestrator │  │  Other Core Services    │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
    NATS JetStream               CNPG/Timescale
```

### Key Components

1. **EventWriter.Supervisor**: DynamicSupervisor managing stream consumers
2. **EventWriter.Broadway**: Broadway pipeline for NATS JetStream consumption
3. **EventWriter.Processor**: Batched insert logic for each message type
4. **EventWriter.Config**: Configuration from environment/config files

### Message Processing Flow

1. Broadway producer fetches messages from NATS JetStream
2. Messages are batched (configurable batch size, e.g., 100)
3. Processor transforms messages to Ecto changesets
4. Batch insert to CNPG hypertables
5. Acknowledge messages on successful insert
6. On failure: NACK for retry or dead-letter

### Supported Streams (from current config)

| Stream | Subject | Table |
|--------|---------|-------|
| TELEMETRY | telemetry.> | timeseries_metrics |
| EVENTS | events.> | events |
| SWEEP | sweep.> | sweep_host_states |
| NETFLOW | netflow.> | netflow_metrics |
| OTEL_METRICS | otel.metrics.> | otel_metrics |
| OTEL_TRACES | otel.traces.> | otel_traces |
| LOGS | logs.> | logs |

## Dependencies

- `off_broadway_nats` or custom Broadway producer for NATS JetStream
- `gnat` for NATS connection (already in deps)
- Existing `ServiceRadar.Repo` for database access

## Migration Path

1. Implement Elixir EventWriter in core-elx
2. Test with docker-compose alongside Go db-event-writer (disabled)
3. Remove Go db-event-writer from docker-compose default services
4. Deprecate Go db-event-writer binary (keep for backwards compatibility)
5. Remove Go db-event-writer in future release

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Message loss during migration | Run both systems briefly, verify counts |
| Performance regression | Benchmark batched inserts, tune batch size |
| NATS library incompatibility | Use well-maintained `gnat` library already in deps |

## Success Criteria

1. All current message types processed correctly
2. No message loss during normal operation
3. Graceful handling of NATS disconnection/reconnection
4. Telemetry metrics for throughput and latency
5. db-event-writer container removed from default compose stack
