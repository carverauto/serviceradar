## ADDED Requirements

### Requirement: The StarRocks dialect fails closed
The system SHALL reject, with an invalid-request error, any SRQL plan carrying a clause, field or ordering that the StarRocks dialect does not implement, and SHALL NOT compile such a plan by omitting the unimplemented part.

#### Scenario: A rollup clause the dialect does not implement
- **WHEN** a query for a cut-over dataset carries `rollup_stats:` and the StarRocks dialect has no implementation for it
- **THEN** translation fails with an error naming the clause
- **AND** it does not return raw rows that a caller would read as zero counts

#### Scenario: A new SRQL clause is introduced
- **WHEN** the parser gains a plan feature and only the CNPG dialect implements it
- **THEN** StarRocks translation of a plan using it is an error until the feature is implemented there

### Requirement: Warehouse downsamples match CNPG semantics
The system SHALL compute, on the StarRocks dialect, a counter `rate` as the change between consecutive samples of one physical counter over real elapsed time with wrap recovery and reset suppression, SHALL split a series by `core_id` or `tags.<key>` with the key validated before it reaches SQL, and SHALL honour `sort:<time>:desc` with a limit as the newest buckets returned oldest first.

#### Scenario: Interface rate chart
- **WHEN** an interface rate chart is read from the warehouse for a port whose cumulative counter is hundreds of gigabytes
- **THEN** the charted values are per-second rates no greater than the port can carry
- **AND** they equal the values CNPG computes for the same samples

#### Scenario: Long chart with a point limit
- **WHEN** a 30-day chart is limited to fewer buckets than the window holds and asks for descending order
- **THEN** the newest buckets are returned, in ascending order

### Requirement: Warehouse rollups answer rollup statistics
The system SHALL answer `rollup_stats:` queries for cut-over datasets from day-partitioned warehouse rollups equivalent to the CNPG continuous aggregates they replace, and SHALL fall back to the warehouse raw table, never to CNPG, when a rollup is stale or missing.

#### Scenario: Log severity cards
- **WHEN** the logs dataset is cut over and a severity summary is requested
- **THEN** the counts come from the warehouse severity rollup
- **AND** they equal the counts CNPG returns for the same rows
