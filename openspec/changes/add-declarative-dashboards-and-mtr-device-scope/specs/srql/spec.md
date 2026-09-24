## MODIFIED Requirements

### Requirement: MTR Hops SRQL Entity

The SRQL service SHALL expose `platform.mtr_hops` as the `in:mtr_hops` query entity, supporting time-range filtering, field equality and pattern filters, and `stats:` aggregations grouped by hop address, ASN, ASN organization, hop number, target address, or device identifier.

Supported filter fields: `trace_id` (UUID equality), `addr` (text, supports `%` wildcards), `hostname` (text, supports `%` wildcards), `asn` (integer equality), `asn_org` (text, supports `%` wildcards), `hop_number` (integer equality and range), `target_ip` (text, supports `%` wildcards), `device_id` (text equality).

Supported `stats:` aggregation functions on numeric columns: `avg`, `min`, `max`, `sum`, `count`, and the two-argument aggregates `loss_ratio(<sent>, <received>)` and `wavg(<value>, <weight>)`. Aggregatable columns: `loss_pct`, `avg_us`, `min_us`, `max_us`, `jitter_us`, `sent`, `received`. Supported `by` grouping fields: `addr`, `asn`, `asn_org`, `hop_number`, `target_ip`, `device_id`, and `time:<duration>` (time-bucket grouping; not emitted by the query builder).

Default ordering: `time DESC, id DESC`. Stats queries order by the first aggregated alias descending by default.

#### Scenario: Hop-level loss aggregation by address
- **WHEN** a client sends `in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr sort:loss:desc limit:50`
- **THEN** SRQL returns rows of `{"addr": "...", "loss": F}` sorted highest loss first
- **AND** only hops within the last 24 hours are included

#### Scenario: Latency aggregation by ASN
- **WHEN** a client sends `in:mtr_hops time:last_6h asn:>0 stats:wavg(avg_us, received) as latency by asn sort:latency:desc`
- **THEN** SRQL returns rows of `{"asn": N, "latency": F}` grouped by ASN number, excluding hops with unresolved ASNs

#### Scenario: Trace-scoped hop listing
- **WHEN** a client sends `in:mtr_hops trace_id:some-uuid sort:hop_number:asc`
- **THEN** SRQL returns all hop rows for that trace in hop-number order with full per-hop fields

#### Scenario: Device-scoped hop aggregation
- **WHEN** a client sends `in:mtr_hops time:last_24h target_ip:192.0.2.10 stats:loss_ratio(sent, received) as loss by addr`
- **THEN** SRQL returns per-address loss aggregated only over hops from traces targeting that address

#### Scenario: Unsupported filter field is rejected
- **WHEN** a client sends `in:mtr_hops gateway_id:some-id`
- **THEN** SRQL returns an `InvalidRequest` error naming the unsupported field

#### Scenario: Time range limits hop rows
- **WHEN** a client sends `in:mtr_hops time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z]`
- **THEN** only hop rows with `time >= 2026-01-01T00:00:00Z AND time < 2026-01-02T00:00:00Z` are returned

## REMOVED Requirements

### Requirement: MTR Traces Rejects stats Clauses

Removed. `in:mtr_traces` now supports `stats:` aggregation (see "Trace-level aggregation yields reach rate per target" in the ADDED section). The blanket rejection was replaced because hop-level entity (`in:mtr_hops`) could not name a device until this change, making the advice in the old error text ("use `in:mtr_hops`") a dead end.

## ADDED Requirements

### Requirement: Hop metrics can be scoped to the devices they were measured against

The SRQL service SHALL accept `target_ip` and `device_id` as filter fields on `in:mtr_hops`, so hop-level loss and latency can be restricted to a chosen set of devices.

Hop rows SHALL carry the target attribution of the trace they belong to. Without it, hop metrics and device identity sit on opposite sides of a join SRQL cannot cross, and no fleet-scoped hop aggregate is expressible at all.

`target_ip` SHALL be treated as the reliable attribution key. On the bulk-scheduled path a trace's `device_id` holds the originating command's identifier rather than a device uid, so grouping by `device_id` alone yields one row per command and answers nothing. `device_id` remains available because it is a true device uid on the single-run path.

#### Scenario: Hop loss scoped to one device
- **WHEN** a client sends `in:mtr_hops time:last_24h target_ip:192.0.2.10 stats:loss_ratio(sent, received) as loss by addr`
- **THEN** only hops from traces targeting that address are aggregated

#### Scenario: Hop metrics scoped to a set of devices
- **WHEN** a client filters `in:mtr_hops` by a list of target addresses
- **THEN** the aggregate covers only those targets

#### Scenario: Grouping by device_id on bulk-scheduled traces is documented as unreliable
- **GIVEN** traces produced by the bulk scheduler
- **WHEN** a caller groups hop metrics by `device_id`
- **THEN** the grouping reflects originating commands rather than devices
- **AND** the catalog and error text direct the caller to `target_ip`

### Requirement: Trace-level aggregation yields reach rate per target

The SRQL service SHALL support `stats:` aggregation on `in:mtr_traces`, grouping by `target_ip`, `device_id`, `agent_id` or `protocol`, and SHALL make the proportion of traces reaching their target derivable from trace counts and `target_reached`.

This answers a question hop-level data cannot: a trace that never reaches its target has no terminal hop to measure, so the fact that a device is unreachable is only visible at trace level. It is the endpoint signal, as distinct from which path segment is lossy.

The previous blanket refusal of `stats:` on this entity SHALL be replaced. Its error text advised callers to use `in:mtr_hops` for hop-level analytics, which was not a usable alternative because that entity could not name a device.

#### Scenario: Reach rate per target
- **WHEN** a client sends `in:mtr_traces time:last_24h stats:count() as traces by target_ip`
- **THEN** SRQL returns per-target trace counts
- **AND** the reached proportion is derivable for each target

#### Scenario: A stats clause on mtr_traces is no longer refused outright
- **WHEN** a client sends a grouped `stats:` query against `in:mtr_traces`
- **THEN** it is aggregated rather than rejected

#### Scenario: An unsupported grouping is still refused
- **WHEN** a client groups `in:mtr_traces` by a field the entity does not support
- **THEN** SRQL returns an invalid-request error naming the field
- **AND** it does not silently return raw rows
