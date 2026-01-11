# db-batch-writes Specification

## Purpose
TBD - created by archiving change fix-pgx-batch-error-handling. Update Purpose after archive.
## Requirements
### Requirement: CNPG batch writes surface per-command errors
The system SHALL consume results for every queued CNPG batch command and MUST surface the first per-command write error to the caller for non-best-effort write paths.

Batch write error messages MUST include sufficient context to identify which operation failed and which command in the batch produced the error.

#### Scenario: CloudEvent batch insert returns a constraint violation
- **WHEN** `InsertEvents` queues multiple INSERT commands and one command fails due to a database constraint violation
- **THEN** `InsertEvents` returns an error
- **AND** the error includes the failing batch command index and operation context

#### Scenario: User batch insert returns an insert error
- **WHEN** `StoreBatchUsers` queues multiple INSERT commands and one command fails due to invalid data
- **THEN** `StoreBatchUsers` returns an error
- **AND** the error includes the failing batch command index and operation context

### Requirement: Batch results are always closed
The system MUST always close `pgx.BatchResults` after sending a batch, even when a per-command error occurs while reading results.

#### Scenario: Batch results close on early error
- **WHEN** a per-command error is detected while reading batch results
- **THEN** the system closes the batch results before returning

