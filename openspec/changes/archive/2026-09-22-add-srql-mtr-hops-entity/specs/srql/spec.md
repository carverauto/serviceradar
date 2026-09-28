## ADDED Requirements

### Requirement: MTR Hops SRQL Entity
The SRQL service SHALL expose `platform.mtr_hops` as the `in:mtr_hops` query entity, supporting time-range filtering, field equality and pattern filters, and `stats:` aggregations grouped by hop address, ASN, ASN organization, or hop number.

Supported filter fields: `trace_id` (UUID equality), `addr` (text, supports `%` wildcards), `hostname` (text, supports `%` wildcards), `asn` (integer equality), `asn_org` (text, supports `%` wildcards), `hop_number` (integer equality and range).

Supported `stats:` aggregation functions on numeric columns: `avg`, `min`, `max`, `sum`, `count`. Aggregatable columns: `loss_pct`, `avg_us`, `min_us`, `max_us`, `jitter_us`. Supported `by` grouping fields: `addr`, `asn`, `asn_org`, `hop_number`.

Default ordering: `time DESC, id DESC`. Stats queries order by the first aggregated alias descending by default.

#### Scenario: Hop-level loss aggregation by address
- **WHEN** a client sends `in:mtr_hops time:last_24h stats:avg(loss_pct) as avg_loss by addr sort:avg_loss:desc limit:50`
- **THEN** SRQL returns rows of `{"addr": "...", "avg_loss": F}` sorted highest loss first
- **AND** only hops within the last 24 hours are included

#### Scenario: Latency aggregation by ASN
- **WHEN** a client sends `in:mtr_hops time:last_6h stats:avg(avg_us) as avg_latency by asn sort:avg_latency:desc`
- **THEN** SRQL returns rows of `{"asn": N, "avg_latency": F}` grouped by ASN number

#### Scenario: Trace-scoped hop listing
- **WHEN** a client sends `in:mtr_hops trace_id:some-uuid sort:hop_number:asc`
- **THEN** SRQL returns all hop rows for that trace in hop-number order with full per-hop fields

#### Scenario: Unsupported filter field is rejected
- **WHEN** a client sends `in:mtr_hops device_id:some-id`
- **THEN** SRQL returns an `InvalidRequest` error naming the unsupported field

#### Scenario: Time range limits hop rows
- **WHEN** a client sends `in:mtr_hops time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z]`
- **THEN** only hop rows with `time >= 2026-01-01T00:00:00Z AND time < 2026-01-02T00:00:00Z` are returned

### Requirement: MTR Traces Rejects stats Clauses
The SRQL service SHALL return an `InvalidRequest` error when a `stats:` clause is present on an `in:mtr_traces` query instead of silently ignoring it.

#### Scenario: stats clause on mtr_traces returns error
- **WHEN** a client sends `in:mtr_traces stats:count() by device_id`
- **THEN** SRQL returns an `InvalidRequest` error indicating that `stats:` is not supported for `mtr_traces`
- **AND** no result rows are returned

#### Scenario: mtr_traces without stats clause succeeds
- **WHEN** a client sends `in:mtr_traces device_id:some-id time:last_1h`
- **THEN** SRQL returns trace rows normally without error
