# observability-signals — edge↔central series-key alignment

## ADDED Requirements

### Requirement: Canonical Series-Key Parity Between Anomalies and Metrics

An edge anomaly verdict and the central metric it was derived from SHALL persist the
**same** `series_key` for the same physical series, computed by the **one** canonical
`TimeseriesSeriesKey` composite over `{metric_type, metric_name, partition, agent_id,
device_id, target_device_ip, if_index}`. The edge's provisional producer key SHALL NOT
be persisted as the canonical `series_key`; it MAY be retained as debug-only metadata.

#### Scenario: An SNMP anomaly joins its metric on series_key

- **GIVEN** an SNMP series whose metric is stored with `series_key = TimeseriesSeriesKey.build(resource fields)`
- **WHEN** the edge emits an anomaly verdict for that same series and central ingests it
- **THEN** the persisted anomaly `series_key` SHALL equal the metric's `series_key`
- **AND** a join of the anomaly to `timeseries_metrics` on `series_key` SHALL return the series' samples

#### Scenario: The edge producer key is not the canonical key

- **GIVEN** an anomaly verdict carrying a structured edge key (e.g. `v2|partition=…`)
- **WHEN** central ingests it
- **THEN** the persisted `series_key` SHALL be the `TimeseriesSeriesKey` value, not the `v2|…` string
- **AND** the `v2|…` key MAY be kept as metadata and a disagreement SHALL be logged

### Requirement: SNMP Anomalies Attribute To The Poll Target, Not The Polling Agent

For a remote SNMP poll, the anomaly's device identity SHALL be the polled target
device (anchored under the gateway-attested `agent_id`), matching the metric — NOT the
polling agent host. The canonical key SHALL be anchored on the attested `agent_id` so
agent-reported target/interface fields are namespaced to that agent and cannot collide
across agents.

#### Scenario: Polled target, not the agent host

- **GIVEN** an SNMP series polled by `agent_id = A` against target `T`, whose metric keys on `device_id = sr:<T>`
- **WHEN** the anomaly for that series is ingested
- **THEN** its canonical `series_key` SHALL be computed with `device_id = sr:<T>` (the target), not with the agent host as the device
- **AND** it SHALL NOT attribute to `agent_id` as the device

### Requirement: Safe Degradation For Unresolvable Series

When the poll-target identity cannot be resolved, the anomaly's `series_key` SHALL be
left un-joinable (the current behavior) rather than coined to a value that could
collide with a different series. The change SHALL be strictly additive — it aligns the
series it can attribute and never produces a wrong alignment.

#### Scenario: Unattributable series does not collide

- **GIVEN** an anomaly whose poll target cannot be resolved (no `target_device_ip`, no canonical device)
- **WHEN** central ingests it
- **THEN** its `series_key` SHALL NOT equal any other series' canonical key
- **AND** the anomaly SHALL simply not join a metric (no false correlation)
