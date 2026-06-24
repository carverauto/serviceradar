# observability-signals — canonical device-identity alignment for anomalies

## ADDED Requirements

### Requirement: Anomalies Resolve To The Same Canonical Device As Their Metric

An ingested anomaly finding SHALL be persisted under the **canonical `sr:` device
identity** of the series it describes — the same `device_id` the metric pipeline
assigns — resolved centrally (for a remote SNMP poll, from `target_device_ip`; for a
host series, from the host identity) via `DeviceCorrelation`. It SHALL NOT be persisted
under the polling `agent_id` or an unreconciled raw host id when a canonical device
exists. Resolution is anchored on the gateway-attested `agent_id`, so agent-reported
target/interface identity is namespaced to that agent and cannot collide across agents.

The anomaly side SHALL resolve `device_id` through the **same** `DeviceCorrelation`
resolution path the metric pipeline's device backfill uses (`metrics.ex` `resolve_device_ids`
→ `DeviceCorrelation.resolve`), so the two cannot fork into a split-brain where the
same series resolves differently. Because `DeviceCorrelation.resolve` is cache-backed,
a conformance/parity check SHALL resolve both the metric and the anomaly sides under
the **same inventory snapshot** so a stale cache cannot make them diverge spuriously.

#### Scenario: Anomaly and metric resolve through the same path

- **GIVEN** a series whose metric `device_id` was assigned by the metric backfill via `DeviceCorrelation.resolve`
- **WHEN** the anomaly for that series is resolved
- **THEN** it SHALL use the same `DeviceCorrelation` resolution (not a parallel resolver)
- **AND** under one inventory snapshot both SHALL yield the same `sr:` device

#### Scenario: An SNMP anomaly resolves to the polled target's canonical device

- **GIVEN** an SNMP series polled by `agent_id = A` against target `T`, whose metric is stored with `device_id = sr:<T>`
- **WHEN** the anomaly for that series is ingested and a canonical device for `T` exists
- **THEN** the finding's resolved device identity SHALL be `sr:<T>`
- **AND** it SHALL NOT be `agent_id = A` nor the raw target IP

#### Scenario: A host (non-SNMP) anomaly resolves to its canonical device

- **GIVEN** a sysmon/process series for a host whose metric is stored with `device_id = sr:<H>`
- **WHEN** the anomaly is ingested and a canonical device for the host exists
- **THEN** the finding's resolved device identity SHALL be `sr:<H>`, not the raw hostname

### Requirement: Disposition And Liveness Join On The Canonical Identity Tuple

Anomaly↔metric correlation SHALL key on the canonical identity tuple `(device_id,
metric_name, if_index)` — which both sides produce deterministically — across the
disposition feed and the stale-alert liveness check, and SHALL NOT key on the metric
`series_key` hash (which is computed with `device_id` empty and includes
producer/ingestion-metadata tags, so it is not reproducible from an anomaly).

#### Scenario: An anomaly joins its metric on the canonical tuple

- **GIVEN** a resolved anomaly with `(device_id = sr:<T>, metric_name = M, if_index = I)`
- **WHEN** the disposition or liveness query correlates it to `timeseries_metrics`
- **THEN** the join SHALL be on `(device_id, metric_name, if_index)`
- **AND** it SHALL return that series' samples

### Requirement: Safe Degradation For Unresolvable Series

The anomaly SHALL retain its raw id and not join when `DeviceCorrelation` cannot
resolve a canonical device (no `target_device_ip`, no matching inventory device) — the
current behavior. The change SHALL be strictly additive: it correlates what it can
resolve and SHALL NOT produce a false correlation. Anomalies already open at cutover
SHALL NOT be orphaned (re-key in place on next evaluation, or remain resolvable by raw id).

#### Scenario: Unresolvable series does not falsely correlate

- **GIVEN** an anomaly whose device cannot be resolved to a canonical `sr:` device
- **WHEN** it is ingested
- **THEN** it SHALL retain its raw identity
- **AND** it SHALL NOT join any other series' metrics
