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
