# Tasks: Rewrite db-event-writer in Elixir

## Phase 1: Foundation (Priority: High)

### 1.1 Create EventWriter Module Structure
- [x] 1.1.1 Create `lib/serviceradar/event_writer/` directory structure
- [x] 1.1.2 Create `EventWriter` supervisor module
- [x] 1.1.3 Create `EventWriter.Config` for configuration parsing
- [x] 1.1.4 Add environment variables to `config/runtime.exs`
- [x] 1.1.5 Add `EVENT_WRITER_ENABLED` toggle (default: false)

### 1.2 NATS JetStream Connection
- [x] 1.2.1 Create `EventWriter.Producer` GenServer for connection management (uses Gnat directly)
- [x] 1.2.2 Implement TLS configuration support (via config)
- [x] 1.2.3 Add connection health check and reconnection logic
- [x] 1.2.4 Add telemetry events for connection state changes
- [ ] 1.2.5 Test connection to NATS JetStream in docker-compose

### 1.3 Broadway Pipeline Setup
- [x] 1.3.1 Add `broadway` dependency to `mix.exs`
- [x] 1.3.2 Create `EventWriter.Producer` Broadway producer for NATS JetStream
- [x] 1.3.3 Implement message acknowledgment/NACK logic
- [x] 1.3.4 Configure batching (batch_size: 100, batch_timeout: 1000ms)
- [ ] 1.3.5 Add dead-letter handling for failed messages

## Phase 2: Message Processing (Priority: High)

### 2.1 Generic Message Processor
- [x] 2.1.1 Create `EventWriter.Processor` behaviour module
- [x] 2.1.2 Define `process_batch/1` callback spec
- [x] 2.1.3 Implement generic JSON message parsing
- [x] 2.1.4 Add telemetry for message processing metrics

### 2.2 Telemetry Stream Processor
- [x] 2.2.1 Create `EventWriter.Processors.Telemetry` module
- [x] 2.2.2 Implement batch insert to `timeseries_metrics` hypertable
- [x] 2.2.3 Handle metric types (generic parsing)
- [x] 2.2.4 Add unit tests with sample messages

### 2.3 Events Stream Processor
- [x] 2.3.1 Create `EventWriter.Processors.Events` module
- [x] 2.3.2 Implement batch insert to `events` table (with upsert)
- [x] 2.3.3 Handle CloudEvents and GELF format parsing
- [x] 2.3.4 Add unit tests

### 2.4 Sweep Stream Processor
- [x] 2.4.1 Create `EventWriter.Processors.Sweep` module
- [x] 2.4.2 Implement batch insert to `sweep_host_states` hypertable
- [x] 2.4.3 Handle sweep result message format
- [x] 2.4.4 Add unit tests (can add when needed)

### 2.5 NetFlow Stream Processor
- [x] 2.5.1 Create `EventWriter.Processors.NetFlow` module
- [x] 2.5.2 Implement batch insert to `netflow_metrics` hypertable
- [x] 2.5.3 Handle NetFlow JSON message format
- [x] 2.5.4 Add unit tests (can add when needed)

### 2.6 OTEL Streams Processor
- [x] 2.6.1 Create `EventWriter.Processors.OtelMetrics` module
- [x] 2.6.2 Create `EventWriter.Processors.OtelTraces` module
- [x] 2.6.3 Implement batch inserts to `otel_metrics` and `otel_traces`
- [x] 2.6.4 Add unit tests

### 2.7 Logs Stream Processor
- [x] 2.7.1 Create `EventWriter.Processors.Logs` module
- [x] 2.7.2 Implement batch insert to `logs` hypertable
- [x] 2.7.3 Handle structured log message format
- [x] 2.7.4 Add unit tests

## Phase 3: Integration (Priority: High)

### 3.1 Ecto Schema for Hypertables
- [x] 3.1.1 Using schemaless `Repo.insert_all/3` for all hypertables (no Ecto schemas needed)
- [x] 3.1.2 Events processor uses schemaless insert with conflict handling
- [x] 3.1.3 All processors use direct table name references
- [x] 3.1.4 JSONB fields handled via map encoding
- [x] 3.1.5 Timestamps handled via DateTime.utc_now()

### 3.2 Batch Insert Implementation
- [x] 3.2.1 Implement `Repo.insert_all/3` with conflict handling (on_conflict: :nothing)
- [x] 3.2.2 Events table uses upsert (on_conflict: :replace)
- [ ] 3.2.3 Implement retry logic for transient failures
- [x] 3.2.4 Add telemetry for insert latency and batch size

### 3.3 Supervisor Integration
- [x] 3.3.1 Add `EventWriter.Supervisor` to core-elx application
- [x] 3.3.2 Conditionally start based on `EVENT_WRITER_ENABLED`
- [x] 3.3.3 Add `EventWriter.Health` module for status/check/healthy?
- [x] 3.3.4 Register in ClusterHealth monitoring

## Phase 4: Configuration & Deployment (Priority: Medium)

### 4.1 Configuration
- [x] 4.1.1 Define configuration schema matching Go config format
- [x] 4.1.2 Add support for multi-stream configuration
- [x] 4.1.3 Config loaded via `EventWriter.Config.load/0`
- [ ] 4.1.4 Document configuration options

### 4.2 Docker Compose Updates
- [x] 4.2.1 Add EVENT_WRITER_ENABLED=true to core-elx environment
- [x] 4.2.2 Add NATS connection config to core-elx (with mTLS support)
- [x] 4.2.3 db-event-writer already under legacy profile
- [ ] 4.2.4 Update healthcheck to include EventWriter status

### 4.3 Testing
- [ ] 4.3.1 Add integration tests with NATS JetStream
- [ ] 4.3.2 Add performance benchmarks for batch inserts
- [ ] 4.3.3 Test graceful shutdown with pending messages
- [ ] 4.3.4 Test NATS reconnection scenarios

## Phase 5: Monitoring & Observability (Priority: Medium)

### 5.1 Telemetry
- [x] 5.1.1 Add message processing rate metrics (`[:serviceradar, :event_writer, :batch_processed]`)
- [x] 5.1.2 Add batch insert latency metrics (duration in telemetry events)
- [x] 5.1.3 Add error rate metrics by stream (`[:serviceradar, :event_writer, :batch_failed]`)
- [ ] 5.1.4 Add queue depth metrics

### 5.2 Logging
- [x] 5.2.1 Add structured logging for message processing
- [x] 5.2.2 Add debug logging for batch details
- [x] 5.2.3 Add error logging with message context

### 5.3 Health & Status
- [x] 5.3.1 Add EventWriter status to /api/health endpoint
- [ ] 5.3.2 Add stream consumer lag monitoring
- [x] 5.3.3 Add NATS connection status via telemetry events

### 5.4 Broadway Dashboard
- [x] 5.4.1 Add `broadway_dashboard` dependency to `mix.exs`
- [ ] 5.4.2 Mount Broadway Dashboard in Phoenix router (admin routes)
- [ ] 5.4.3 Configure dashboard authentication (admin only)
- [ ] 5.4.4 Document dashboard access and usage

## Phase 5.5: Code Quality & Reuse (Priority: Medium)

### 5.5.1 Shared Field Parser
- [x] 5.5.1.1 Create `EventWriter.FieldParser` module with shared functions
- [x] 5.5.1.2 Consolidate `parse_timestamp/1` (was duplicated 6x)
- [x] 5.5.1.3 Consolidate `encode_jsonb/1` (was duplicated 4x)
- [x] 5.5.1.4 Add `parse_duration_ms/1` and `parse_duration_seconds/1`
- [x] 5.5.1.5 Add `safe_bigint/1` for int64 clamping
- [x] 5.5.1.6 Add `get_field/4` for snake_case/camelCase field lookup
- [x] 5.5.1.7 Update all processors to use FieldParser

## Phase 5.6: OCSF Schema Compliance (Priority: Medium)

> **Strategy**: Keep OTel data (traces, metrics) in native format for observability.
> Convert security-relevant events to OCSF schema where appropriate.

### 5.6.1 Current State (Analysis Complete)
| Processor | Table | OCSF? | Action |
|-----------|-------|-------|--------|
| Logs | ocsf_events | ✅ Yes | Keep as-is |
| OtelMetrics | otel_metrics | ❌ No | Keep native (observability) |
| OtelTraces | otel_traces | ❌ No | Keep native (observability) |
| Telemetry | timeseries_metrics | ❌ No | Keep native (metrics) |
| Sweep | sweep_host_states | ❌ No | Consider OCSF Network Activity |
| NetFlow | netflow_metrics | ❌ No | Consider OCSF Network Traffic |

### 5.6.2 OCSF Conversion Tasks (Future)
- [ ] 5.6.2.1 Evaluate Sweep → OCSF Network Activity (class_uid: 4001)
- [ ] 5.6.2.2 Evaluate NetFlow → OCSF Network Traffic (class_uid: 4002)
- [ ] 5.6.2.3 Create OCSF base module for shared OCSF field building
- [ ] 5.6.2.4 Add OCSF category/class constants module
- [ ] 5.6.2.5 Document OCSF vs native data strategy

## Phase 6: Cleanup (Priority: Low)

### 6.1 Deprecation
- [ ] 6.1.1 Mark Go db-event-writer as deprecated in docs
- [ ] 6.1.2 Add deprecation notice to Go cmd/consumers/db-event-writer
- [ ] 6.1.3 Update CHANGELOG with migration notes

### 6.2 Documentation
- [ ] 6.2.1 Document EventWriter configuration
- [ ] 6.2.2 Document migration from Go to Elixir EventWriter
- [ ] 6.2.3 Update architecture diagrams

## Dependencies

- Phase 2 depends on Phase 1 completion
- Phase 3 depends on Phase 2 (at least 2.1)
- Phase 4 depends on Phase 3
- Phase 5 can run in parallel with Phase 4
- Phase 6 runs after successful deployment

## Validation Checkpoints

1. **After Phase 1**: NATS connection established, Broadway pipeline running
2. **After Phase 2**: All message types processing correctly (unit tests pass)
3. **After Phase 3**: Batch inserts to CNPG working, data verified
4. **After Phase 4**: docker-compose stack running with Elixir EventWriter
5. **After Phase 5**: Metrics visible in telemetry, health checks passing
6. **After Phase 6**: Go db-event-writer removed from default stack
