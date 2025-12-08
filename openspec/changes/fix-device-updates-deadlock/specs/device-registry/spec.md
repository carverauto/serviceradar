## MODIFIED Requirements

### Requirement: Device Update Persistence
The system SHALL persist device updates to CNPG storage with serialized write access to prevent deadlocks.

When multiple concurrent callers invoke device update operations, the system MUST serialize database writes using a Go-level mutex to eliminate circular lock dependencies.

The system SHALL classify PostgreSQL error codes 40P01 (deadlock_detected) and 40001 (serialization_failure) as transient errors eligible for automatic retry.

#### Scenario: Concurrent device updates without deadlock
- **WHEN** two or more goroutines call `ProcessBatchDeviceUpdates` simultaneously with overlapping device IDs
- **THEN** the operations complete successfully without deadlock errors
- **AND** all device data is persisted correctly to `unified_devices` and `device_updates` tables

#### Scenario: Transient deadlock with automatic retry
- **WHEN** a deadlock error (SQLSTATE 40P01) occurs during a batch operation
- **THEN** the system retries the operation with exponential backoff
- **AND** the retry succeeds within the configured maximum attempts
- **AND** a metric `cnpg_device_updates_retry_success_total` is incremented

#### Scenario: Deadlock metric recording
- **WHEN** a deadlock error occurs during device update persistence
- **THEN** the system increments the `cnpg_device_updates_deadlock_total` metric
- **AND** logs the error with SQLSTATE code and batch context

### Requirement: Device Identifier Registration
The system SHALL register device identifiers with serialized write access to prevent deadlocks on the `device_identifiers` table's unique constraint.

#### Scenario: Concurrent identifier registration without deadlock
- **WHEN** multiple goroutines call `RegisterDeviceIdentifiers` with identifiers that share the same (identifier_type, identifier_value, partition) tuple
- **THEN** the operations complete successfully using ON CONFLICT upsert semantics
- **AND** no deadlock errors occur due to mutex serialization

## ADDED Requirements

### Requirement: CNPG Write Serialization
The system SHALL provide a mutex-based serialization mechanism for all CNPG device-related batch writes.

The serialization mechanism SHALL:
- Protect `cnpgInsertDeviceUpdates`, `UpsertDeviceIdentifiers`, and `StoreNetworkSightings` operations
- Use a single mutex to ensure atomicity across related table writes
- Release the mutex immediately after batch execution completes

#### Scenario: Mutex acquisition timing
- **WHEN** a device update batch is submitted for persistence
- **THEN** the system acquires the write mutex before sending the batch to PostgreSQL
- **AND** releases the mutex after the batch completes (success or failure)
- **AND** does not hold the mutex during JSON marshaling or other pre-processing

### Requirement: CNPG Transient Error Handling
The system SHALL implement automatic retry with exponential backoff for transient PostgreSQL errors in device update operations.

Configuration options:
- `CNPG_DEADLOCK_BACKOFF_MS`: Base backoff duration in milliseconds (default: 500)
- `CNPG_MAX_RETRY_ATTEMPTS`: Maximum retry attempts before failure (default: 3)

#### Scenario: Exponential backoff calculation
- **WHEN** a transient error triggers a retry
- **THEN** the backoff duration is calculated as: `base * 2^(attempt-1) + random_jitter`
- **AND** jitter is between 0 and 100% of the base duration
- **AND** the system waits for the calculated duration before retrying

#### Scenario: Maximum retry exhaustion
- **WHEN** all retry attempts are exhausted without success
- **THEN** the operation fails with the last encountered error
- **AND** the `cnpg_device_updates_deadlock_total` metric reflects the failure
- **AND** the error is logged with full context including attempt count
