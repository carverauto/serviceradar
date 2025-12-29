# Tasks: Rewrite db-event-writer in Elixir

## Phase 1: Foundation (Priority: High)

### 1.1 Create EventWriter Module Structure
- [ ] 1.1.1 Create `lib/serviceradar/event_writer/` directory structure
- [ ] 1.1.2 Create `EventWriter` supervisor module
- [ ] 1.1.3 Create `EventWriter.Config` for configuration parsing
- [ ] 1.1.4 Add environment variables to `config/runtime.exs`
- [ ] 1.1.5 Add `EVENT_WRITER_ENABLED` toggle (default: false)

### 1.2 NATS JetStream Connection
- [ ] 1.2.1 Create `EventWriter.NatsConnection` GenServer for connection management
- [ ] 1.2.2 Implement mTLS configuration using existing cert paths
- [ ] 1.2.3 Add connection health check and reconnection logic
- [ ] 1.2.4 Add telemetry events for connection state changes
- [ ] 1.2.5 Test connection to NATS JetStream in docker-compose

### 1.3 Broadway Pipeline Setup
- [ ] 1.3.1 Add `broadway` dependency to `mix.exs`
- [ ] 1.3.2 Create `EventWriter.Producer` Broadway producer for NATS JetStream
- [ ] 1.3.3 Implement message acknowledgment/NACK logic
- [ ] 1.3.4 Configure batching (batch_size: 100, batch_timeout: 1000ms)
- [ ] 1.3.5 Add dead-letter handling for failed messages

## Phase 2: Message Processing (Priority: High)

### 2.1 Generic Message Processor
- [ ] 2.1.1 Create `EventWriter.Processor` behaviour module
- [ ] 2.1.2 Define `handle_batch/2` callback spec
- [ ] 2.1.3 Implement generic JSON message parsing
- [ ] 2.1.4 Add telemetry for message processing metrics

### 2.2 Telemetry Stream Processor
- [ ] 2.2.1 Create `EventWriter.Processors.Telemetry` module
- [ ] 2.2.2 Implement batch insert to `timeseries_metrics` hypertable
- [ ] 2.2.3 Handle CPU, disk, memory, process metric types
- [ ] 2.2.4 Add unit tests with sample messages

### 2.3 Events Stream Processor
- [ ] 2.3.1 Create `EventWriter.Processors.Events` module
- [ ] 2.3.2 Implement batch insert to `events` table
- [ ] 2.3.3 Handle CloudEvents format parsing
- [ ] 2.3.4 Add unit tests

### 2.4 Sweep Stream Processor
- [ ] 2.4.1 Create `EventWriter.Processors.Sweep` module
- [ ] 2.4.2 Implement batch insert to `sweep_host_states` hypertable
- [ ] 2.4.3 Handle sweep result message format
- [ ] 2.4.4 Add unit tests

### 2.5 NetFlow Stream Processor
- [ ] 2.5.1 Create `EventWriter.Processors.NetFlow` module
- [ ] 2.5.2 Implement batch insert to `netflow_metrics` hypertable
- [ ] 2.5.3 Handle NetFlow v5/v9/IPFIX message formats
- [ ] 2.5.4 Add unit tests

### 2.6 OTEL Streams Processor
- [ ] 2.6.1 Create `EventWriter.Processors.OtelMetrics` module
- [ ] 2.6.2 Create `EventWriter.Processors.OtelTraces` module
- [ ] 2.6.3 Implement batch inserts to `otel_metrics` and `otel_traces`
- [ ] 2.6.4 Add unit tests

### 2.7 Logs Stream Processor
- [ ] 2.7.1 Create `EventWriter.Processors.Logs` module
- [ ] 2.7.2 Implement batch insert to `logs` hypertable
- [ ] 2.7.3 Handle structured log message format
- [ ] 2.7.4 Add unit tests

## Phase 3: Integration (Priority: High)

### 3.1 Ecto Schema for Hypertables
- [ ] 3.1.1 Create `EventWriter.Schemas.TimeseriesMetric` schema (schemaless insert)
- [ ] 3.1.2 Create `EventWriter.Schemas.Event` schema
- [ ] 3.1.3 Create `EventWriter.Schemas.SweepHostState` schema
- [ ] 3.1.4 Create `EventWriter.Schemas.NetflowMetric` schema
- [ ] 3.1.5 Create `EventWriter.Schemas.OtelMetric` schema
- [ ] 3.1.6 Create `EventWriter.Schemas.OtelTrace` schema
- [ ] 3.1.7 Create `EventWriter.Schemas.Log` schema

### 3.2 Batch Insert Implementation
- [ ] 3.2.1 Implement `Repo.insert_all/3` with conflict handling
- [ ] 3.2.2 Add transaction wrapping for batch atomicity
- [ ] 3.2.3 Implement retry logic for transient failures
- [ ] 3.2.4 Add telemetry for insert latency and batch size

### 3.3 Supervisor Integration
- [ ] 3.3.1 Add `EventWriter.Supervisor` to core-elx application
- [ ] 3.3.2 Conditionally start based on `EVENT_WRITER_ENABLED`
- [ ] 3.3.3 Add health check endpoint for EventWriter status
- [ ] 3.3.4 Register in ClusterHealth monitoring

## Phase 4: Configuration & Deployment (Priority: Medium)

### 4.1 Configuration
- [ ] 4.1.1 Define configuration schema matching Go config format
- [ ] 4.1.2 Add support for multi-stream configuration
- [ ] 4.1.3 Implement config validation on startup
- [ ] 4.1.4 Document configuration options

### 4.2 Docker Compose Updates
- [ ] 4.2.1 Add EVENT_WRITER_ENABLED=true to core-elx environment
- [ ] 4.2.2 Add NATS connection config to core-elx
- [ ] 4.2.3 Remove db-event-writer from default services
- [ ] 4.2.4 Update healthcheck to include EventWriter status

### 4.3 Testing
- [ ] 4.3.1 Add integration tests with NATS JetStream
- [ ] 4.3.2 Add performance benchmarks for batch inserts
- [ ] 4.3.3 Test graceful shutdown with pending messages
- [ ] 4.3.4 Test NATS reconnection scenarios

## Phase 5: Monitoring & Observability (Priority: Medium)

### 5.1 Telemetry
- [ ] 5.1.1 Add message processing rate metrics
- [ ] 5.1.2 Add batch insert latency metrics
- [ ] 5.1.3 Add error rate metrics by stream
- [ ] 5.1.4 Add queue depth metrics

### 5.2 Logging
- [ ] 5.2.1 Add structured logging for message processing
- [ ] 5.2.2 Add debug logging for batch details
- [ ] 5.2.3 Add error logging with message context

### 5.3 Health & Status
- [ ] 5.3.1 Add EventWriter status to /api/health endpoint
- [ ] 5.3.2 Add stream consumer lag monitoring
- [ ] 5.3.3 Add NATS connection status to cluster health

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
