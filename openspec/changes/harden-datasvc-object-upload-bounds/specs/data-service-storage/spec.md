## ADDED Requirements
### Requirement: Datasvc Object Uploads Are Explicitly Bounded
The datasvc object upload service SHALL enforce a cumulative per-object byte limit and SHALL reject uploads that exceed that bound before the upload is committed as a successful object.

#### Scenario: Oversize object upload is rejected
- **GIVEN** a datasvc writer streams an object whose cumulative payload exceeds the configured upload ceiling
- **WHEN** the upload RPC processes the stream
- **THEN** datasvc rejects the upload with an error
- **AND** it does not return a successful object record for that key

### Requirement: Datasvc Object Storage Has A Capacity Ceiling
Datasvc SHALL create and manage its JetStream object-store bucket with an explicit storage ceiling instead of leaving the bucket unbounded.

#### Scenario: Object store initializes with a configured max-bytes limit
- **GIVEN** datasvc initializes its backing JetStream object-store bucket
- **WHEN** the bucket is created from configuration
- **THEN** the object-store configuration includes an explicit maximum byte capacity
- **AND** datasvc does not rely on an unlimited default object bucket
