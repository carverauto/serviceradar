## ADDED Requirements
### Requirement: Concurrent Sync Batch Ingestion
The system SHALL process sync update batches concurrently with a bounded concurrency limit so that ingestion of one batch does not block later batches for the same tenant.

#### Scenario: Multi-chunk sync results
- **WHEN** multiple sync result chunks arrive for the same tenant
- **THEN** core schedules ingestion for each chunk without waiting for earlier chunks to finish
- **AND** the number of concurrent batch workers SHALL be limited by configuration
