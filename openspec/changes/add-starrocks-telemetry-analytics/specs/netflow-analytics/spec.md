## ADDED Requirements

### Requirement: Exact accelerated flow analytics
The system SHALL preserve exact flow totals, sampling semantics, nullable ports, classification and filter semantics when using StarRocks aggregates, and SHALL use only covered, eligible aggregates with disjoint raw edges or an exact raw fallback.

#### Scenario: Partial aggregate coverage
- **WHEN** a requested interval includes incomplete edge buckets or stale aggregate partitions
- **THEN** uncovered portions use raw data without overlapping covered contributions
- **AND** the result matches synthetic raw ground truth

#### Scenario: Classification requires omitted dimensions
- **WHEN** a source-port or source/destination CIDR rule requires fields absent from an aggregate
- **THEN** the query uses an exact eligible source rather than classifying aggregate rows incorrectly

#### Scenario: Rewrite is unavailable
- **WHEN** StarRocks cannot rewrite a dashboard query to a fresh eligible materialized view
- **THEN** an explicit proven plan or raw fallback maintains correctness
- **AND** profiling exposes the chosen source and latency for acceptance

#### Scenario: Approximation is requested
- **WHEN** an explicitly supported approximate analytical operation is selected
- **THEN** the response identifies approximation and its documented accuracy contract
- **AND** exact traffic totals are not silently replaced by sketches
