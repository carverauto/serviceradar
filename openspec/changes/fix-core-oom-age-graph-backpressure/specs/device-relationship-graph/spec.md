## ADDED Requirements

### Requirement: AGE graph writer prevents OOM through memory-aware backpressure
The system SHALL implement memory-bounded queueing in the AGE graph writer to prevent core OOM crashes when graph write throughput cannot keep pace with incoming updates.

#### Scenario: High ingestion rate with slow AGE response
- **WHEN** device updates arrive faster than AGE can process them
- **AND** the queue depth approaches capacity
- **THEN** the writer drops or rejects new batches instead of accumulating goroutines and memory
- **AND** metrics indicate rejected batches due to backpressure

#### Scenario: Memory threshold triggers early rejection
- **WHEN** Go heap memory exceeds the configured threshold (default 80% of container limit)
- **THEN** the writer rejects new graph batches until memory pressure subsides
- **AND** rejected batches are logged with reason "memory_pressure"

### Requirement: AGE graph writer scales with multiple workers
The system SHALL process AGE graph merges with configurable worker count (default 4) to improve queue drain rate under load.

#### Scenario: Parallel workers drain queue faster
- **GIVEN** AGE_GRAPH_WORKERS=4 (default)
- **WHEN** multiple batches are queued for processing
- **THEN** up to 4 batches are processed concurrently
- **AND** queue depth remains stable during steady-state ingestion

### Requirement: Large payloads are chunked before queueing
The system SHALL split device update batches larger than a configurable threshold into smaller chunks to limit per-request memory footprint.

#### Scenario: Large sync message is chunked
- **WHEN** a sync service reports 16,384 device updates in a single message
- **AND** the chunk threshold is set to 5,000 devices
- **THEN** the updates are split into 4 chunks before entering the queue
- **AND** each chunk is processed independently

### Requirement: Circuit breaker prevents cascading failures
The system SHALL implement a circuit breaker that temporarily disables AGE graph writes after repeated failures to prevent resource exhaustion.

#### Scenario: Circuit opens after failures
- **WHEN** 10 consecutive AGE graph batches fail
- **THEN** the circuit breaker opens and rejects subsequent batches immediately
- **AND** the circuit enters half-open state after 60 seconds to test recovery

#### Scenario: Circuit closes after recovery
- **WHEN** the circuit is half-open
- **AND** a test batch succeeds
- **THEN** the circuit closes and normal processing resumes
