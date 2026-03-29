## MODIFIED Requirements

### Requirement: Identity Cache MUST Remain Bounded Under Pressure
The identity cache SHALL enforce its size limit without materializing the full ETS table into the cache server process during eviction.

#### Scenario: Cache exceeds the configured soft size limit
- **WHEN** the cache grows beyond its maximum configured size
- **THEN** eviction MUST remove older entries using a bounded-memory strategy
- **AND** the cache server MUST NOT copy the entire table into process memory to perform eviction
