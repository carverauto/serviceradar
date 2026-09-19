## ADDED Requirements

### Requirement: NetFlow collection is independent of StarRocks
The system SHALL leave NetFlow collection independently gated by Helm and Compose, SHALL keep NetFlow collection and serving working when StarRocks analytics is disabled, and SHALL NOT treat StarRocks as a NetFlow-only store.

#### Scenario: Collector enablement without the warehouse
- **WHEN** `flowCollector.enabled` is true and `analytics.starrocks.enabled` is false
- **THEN** the collector is deployed and installation does not fail
- **AND** CNPG hypertables remain the NetFlow store and serving path

#### Scenario: Warehouse without NetFlow
- **WHEN** `analytics.starrocks.enabled` is true and `flowCollector.enabled` is false
- **THEN** the NetFlow collector is not deployed
- **AND** other telemetry datasets may still persist to StarRocks

### Requirement: Exact accelerated flow analytics
The system SHALL preserve exact flow totals, sampling semantics, nullable ports, classification and filter semantics when using StarRocks aggregates, SHALL read an hourly aggregate only when the requested bucket, filters and aggregation re-aggregate from it exactly, and SHALL otherwise read the exact raw table.
An hourly aggregate answers at its own hour grain. Requested windows are not hour-aligned, so an edge hour that overlaps the window is returned whole, including traffic just outside the request, and the warehouse alone answers it -- edges are never completed from CNPG or a second store.

#### Scenario: Window bound falls inside an hour
- **WHEN** a bucketed flow query starts or ends part way through an hour and the hourly aggregate is eligible
- **THEN** every hourly row whose hour overlaps the window contributes in full
- **AND** the edge buckets are not completed from CNPG or a separate raw query

#### Scenario: Requested shape the aggregate cannot reproduce
- **WHEN** the bucket is shorter than an hour, or a filter, series or value field is absent from the hourly aggregate
- **THEN** the query reads the raw StarRocks table instead
- **AND** the result matches synthetic raw ground truth

#### Scenario: Classification requires omitted dimensions
- **WHEN** a source-port or source/destination CIDR rule requires fields absent from an aggregate
- **THEN** the query uses an exact eligible source rather than classifying aggregate rows incorrectly

#### Scenario: Rewrite is unavailable
- **WHEN** StarRocks cannot rewrite a dashboard query to a fresh eligible materialized view
- **THEN** an explicit proven plan or raw fallback maintains correctness
- **AND** profiling exposes the chosen source and latency for acceptance

#### Scenario: A materialized view has fallen behind its source
- **WHEN** an hourly view's newest bucket trails the newest row of the table it aggregates by more than the configured tolerance
- **THEN** the query is served from the StarRocks raw table instead, never from CNPG
- **AND** a view that is level with an idle source table is still read, because freshness is the view's lag behind that source rather than its age against the wall clock
- **AND** any probe error, empty result or unreadable high-water mark is treated as stale

#### Scenario: Approximation is requested
- **WHEN** an explicitly supported approximate analytical operation is selected
- **THEN** the response identifies approximation and its documented accuracy contract
- **AND** exact traffic totals are not silently replaced by sketches

### Requirement: Flow attribution and enrichment use the CNPG catalog
The system SHALL join StarRocks-served flow history to CNPG current-state attribution and enrichment through the JDBC catalog, and SHALL NOT dual-query those stores in application code.

#### Scenario: Live process correlation on historical flows
- **WHEN** an authorized caller asks for current process attribution on StarRocks-served flows
- **THEN** the query joins `serviceradar.ocsf_network_activity` to allowlisted CNPG process-correlation current-state
- **AND** traffic totals come only from the StarRocks observation
- **AND** the correlator does not write StarRocks

#### Scenario: Prefix-tag or device enrichment
- **WHEN** an authorized caller filters or groups StarRocks-served flows by current prefix tags or device identity
- **THEN** StarRocks joins the allowlisted CNPG enrichment tables
- **AND** EventWriter ingest-time tag snapshots on the observation remain unchanged
