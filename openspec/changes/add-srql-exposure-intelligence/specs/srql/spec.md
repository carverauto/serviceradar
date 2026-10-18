## ADDED Requirements

### Requirement: SRQL Exposure Entity
SRQL SHALL provide `in:exposure` (aliases `exposures` and `exposure_facts`) over current actionable exposure facts in StarRocks, with one row per device, package identity and CVE.

**Fields.** Rows SHALL expose:
- device: `device_id`, `hostname`, `site`, `vlan`, `owner`, `partition`, `agent_managed`;
- package: `package_name`, `installed_version`, `fixed_version`, `source_scope`;
- CVE: `cve_id`, `severity`, `cvss_score`, `kev`, `exploit_available`, `epss_score`;
- lifecycle: `first_exposed_at`, `updated_at`.

**Exposure filters.** The entity SHALL accept `cve`, `kev`, `exploit_available`, `severity`, `cvss_score`, `epss_score`, `package`, `device_id`, `hostname`, `site`, `tag`, `vlan`, `owner`, `tags.<key>` and `agent_managed`.

**Evidence filters.** These require a time window, and SHALL default to `last_24h` when `time:` is omitted: `contacted_threat`, `inbound_internet`, `listening`, `provenance` and `namespace`. When one is present, rows SHALL add `contact_count`, `distinct_peers`, `last_contact` and `provenance`.

**Defaults.** The default sort SHALL be `kev desc, cvss_score desc, hostname asc, device_id asc`. Resolved facts SHALL NOT be returned.

#### Scenario: CVE lookup
- **WHEN** a client runs `in:exposure cve:cve-2024-0001 sort:hostname:asc limit:200`
- **THEN** SRQL folds the identifier to `CVE-2024-0001`, compiles a range scan on its ordinal over active facts, and returns the exposed rows

#### Scenario: Evidence predicate composes with an exposure predicate
- **WHEN** a client runs `in:exposure kev:true contacted_threat:true time:last_24h limit:100`
- **THEN** SRQL restricts the result to KEV-exposed devices that have evidence of contact with a matched indicator in the window
- **AND** each row carries contact count, last contact and provenance

#### Scenario: Evidence predicate without a time window
- **WHEN** a client runs `in:exposure inbound_internet:true`
- **THEN** SRQL applies `time:last_24h` and states the applied window in the response

#### Scenario: Unsupported field is rejected
- **WHEN** a client runs `in:exposure cmdline:%ssh%`
- **THEN** SRQL returns an unsupported filter field error that names `cmdline`

### Requirement: SRQL Distinct Device Counting
SRQL SHALL support the aggregate `count_distinct(device_id)` on `in:exposure`, `in:exposure_history` and `in:observed_connections`, evaluated as a bitmap union count over device ordinals. It SHALL be groupable by `cve_id`, `severity`, `kev`, `site`, `tag`, `vlan`, `owner`, `tags.<key>` and, on history, `day`. Grouped results SHALL follow the existing grouped-query limit and cursor contract.

#### Scenario: Hosts per site
- **WHEN** a client runs `in:exposure severity:critical stats:"count_distinct(device_id) as hosts by site" limit:50`
- **THEN** one row per site is returned with its distinct device count
- **AND** a device exposed to several matching CVEs is counted once per site

#### Scenario: Unsupported distinct field
- **WHEN** a client runs `in:exposure stats:"count_distinct(package_name) as n"`
- **THEN** SRQL returns an invalid-request error stating that `count_distinct` supports only `device_id`

### Requirement: SRQL Observed Connections Entity
SRQL SHALL provide `in:observed_connections` (aliases `connection_evidence` and `contacts`) over the hourly observed-connection evidence set.

**Fields.** Rows SHALL expose:
- `time` (the hour), `device_id`, `hostname`, `direction`, `protocol`, `service_port`;
- `peer_ip`, `peer_scope`, `process`, `package`, `workload`;
- `provenance`, `host_connections`, `network_flows`, `host_bytes`, `network_bytes`;
- `first_seen`, `last_seen`.

**Filters.** The entity SHALL accept:
- the threat filters `threat_matched`, `threat_source`, `threat_indicator` and `threat_severity`, with the same semantics as on `in:flows`;
- the exposure pivots `exposed`, `exposure_cve`, `exposure_kev` and `exposure_severity`;
- `listening`, `package_known` and `provenance`.

**Bounds.** A time window SHALL be required, defaulting to `last_24h`.

#### Scenario: Evidence for an exposed host
- **WHEN** a client runs `in:observed_connections exposure_kev:true threat_matched:true time:last_24h sort:last_seen:desc limit:100`
- **THEN** each row is one contact of a KEV-exposed device with a matched peer, reported once with its provenance

#### Scenario: Provenance is a filter and a column
- **WHEN** a client runs `in:observed_connections provenance:corroborated time:last_1h`
- **THEN** only contacts with both host and network evidence are returned, and each row's `provenance` is `corroborated`

### Requirement: SRQL Connection Discrepancies Entity
SRQL SHALL provide `in:connection_discrepancies` (aliases `discrepancies` and `evasion_signals`) over evaluated discrepancy candidates.

**Fields.** Rows SHALL expose:
- `id`, `time`, `kind` (`network_only` or `host_only`), `outcome` (`signal` or `suppressed`), `reason`;
- `device_id`, `agent_id`, `local_ip`, `local_port`, `peer_ip`, `peer_port`, `protocol`;
- `exporter`, `translation`, `tolerance_ms`;
- `confidence` and its factors;
- `evidence_flow_ids`, `incident_id`.

**Filters.** Filters SHALL be supported on every listed field except the evidence references.

**Bounds.** A time window SHALL be required, defaulting to `last_24h`.

#### Scenario: Triage evasion signals
- **WHEN** a client runs `in:connection_discrepancies kind:network_only outcome:signal confidence:>=0.85 time:last_24h sort:confidence:desc`
- **THEN** alert-eligible evasion signals are returned, highest confidence first

#### Scenario: Suppression counts
- **WHEN** a client runs `in:connection_discrepancies outcome:suppressed time:last_24h stats:"count() as n by reason"`
- **THEN** one row per suppression reason is returned

#### Scenario: Pivot from signal to flows
- **GIVEN** a signal for device `sr:00000000-0000-4000-8000-000000000001`
- **WHEN** the client follows its flow pivot `in:attributed_flows dst_device_id:sr:00000000-0000-4000-8000-000000000001 attribution_outcome:no_owner time:[2026-01-01T12:00:00Z,2026-01-01T12:10:00Z]`
- **THEN** the flows that produced the candidate are returned

### Requirement: SRQL Agent Coverage Entity
SRQL SHALL provide `in:agent_coverage` (alias `capture_coverage`) over agent capture coverage attestations.

**Fields.** Rows SHALL expose:
- `agent_id`, `device_id`, `interval_start`, `interval_end`;
- `capture_mode`, `netns_scope`, `complete`;
- `kernel_events_lost`, `events_shed`, `summary_rows_emitted`, `summary_rows_dropped`, `summary_rows_received`;
- `max_publish_lag_ms`, `backpressure`, `restarted`, `clock_offset_ms`, `clock_sync_state`.

**Bounds.** A time window SHALL be required, defaulting to `last_1h`.

#### Scenario: Agent health timeline for an incident
- **WHEN** a client runs `in:agent_coverage agent_id:agent-01 time:[2026-01-01T11:50:00Z,2026-01-01T12:20:00Z] sort:interval_start:asc`
- **THEN** one row per attested interval is returned in order
- **AND** intervals with `complete = false` show the counter that voided them

### Requirement: SRQL Exposure Incidents Entity
SRQL SHALL provide `in:exposure_incidents` over alert incidents that were created from exposure and discrepancy findings.

**Fields.** Rows SHALL expose `incident_id`, `kind`, `severity`, `status`, `device_id`, `hostname`, `first_seen`, `last_seen`, `occurrence_count`, `max_confidence` and a ready-to-run `discrepancies_query` pivot.

**Backing store.** The entity SHALL read the alert engine's incidents and SHALL NOT keep a second incident store.

#### Scenario: Active evasion incidents
- **WHEN** a client runs `in:exposure_incidents status:active kind:network_only sort:last_seen:desc`
- **THEN** active evasion incidents are returned, each with a pivot that lists its discrepancy signals

### Requirement: SRQL Exposure Blast Radius Entity
SRQL SHALL provide `in:exposure_blast_radius` (alias `blast_radius`). It SHALL accept the `in:exposure` exposure filters to select seed devices, `depth` (1-3, default 2), and `via` (`topology`, `bgp`, or a list of both; default `topology`).

**Execution.** It SHALL compile to a two-phase plan. Phase one resolves the seeds in StarRocks; phase two is a bounded traversal parameterized by the seed list.

**Rows.** Rows SHALL expose `device_id`, `hostname`, `hop`, `via_device_id`, `relation`, `seed_device_id` and `truncated`.

**Caps.** More than 500 seeds SHALL return an invalid-request error. A traversal SHALL stop at 5,000 nodes and report `truncated = true`.

#### Scenario: Two-hop topology radius
- **WHEN** a client runs `in:exposure_blast_radius cve:CVE-2024-0001 depth:2 limit:500`
- **THEN** devices within two topology hops of the exposed seeds are returned with hop and path

#### Scenario: Depth out of range
- **WHEN** a client runs `in:exposure_blast_radius kev:true depth:5`
- **THEN** SRQL returns an invalid-request error stating the allowed depth range

### Requirement: SRQL Exposure History Entity
SRQL SHALL provide `in:exposure_history` (alias `exposure_trend`) over daily exposure snapshots and the transition log. Rows SHALL expose `day`, `exposed_hosts`, `exposures`, `newly_exposed_hosts`, `remediated_hosts` and `mean_time_to_remediate`. The entity SHALL accept the `in:exposure` exposure filters, `count_distinct(device_id)` grouped by `day`, and a time window bounded by the history retention.

#### Scenario: KEV trend over ninety days
- **WHEN** a client runs `in:exposure_history kev:true time:last_90d stats:"count_distinct(device_id) as hosts by day"`
- **THEN** one row per day is returned, oldest first

#### Scenario: Window beyond retention
- **GIVEN** history retention is 365 days
- **WHEN** a client queries `time:last_400d`
- **THEN** SRQL returns an invalid-request error that names the retention limit

### Requirement: SRQL Flow Exposure Pivot Filters
SRQL `in:flows` and `in:attributed_flows` SHALL support identical exposure pivot filters `exposed`, `exposure_cve`, `exposure_kev` and `exposure_severity`, evaluated against the device ordinals stamped on each flow side. They SHALL also support `src_device_id` and `dst_device_id`. `in:attributed_flows` SHALL additionally support `attribution_outcome`, `src_attribution_outcome` and `dst_attribution_outcome`. A flow SHALL appear once even when both sides match. Flows ingested before ordinals were stamped SHALL NOT match exposure pivots.

#### Scenario: Flows of exposed devices
- **WHEN** a client runs `in:flows exposure_cve:CVE-2024-0001 time:last_1h sort:time:desc limit:100`
- **THEN** flows with either side on a device exposed to the CVE are returned once each

#### Scenario: Unattributed flows to a covered host
- **WHEN** a client runs `in:attributed_flows dst_attribution_outcome:no_owner exposed:true time:last_1h`
- **THEN** flows whose destination side is an exposed device without an ownership match are returned

### Requirement: SRQL Exposure Read Authorization
SRQL SHALL gate the exposure entities as follows:
- `in:exposure`, `in:exposure_history` and `in:exposure_blast_radius` require `devices.view`;
- `in:observed_connections`, `in:connection_discrepancies` and `in:agent_coverage` require both `devices.view` and `observability.netflow.view`;
- `in:exposure_incidents` requires `observability.alerts.view` and `devices.view`;
- evidence filters on `in:exposure` additionally require `observability.netflow.view`;
- exposure pivot filters on flow entities additionally require `devices.view`.

Every alias SHALL be listed in the entity permission map, so that no alias reaches execution ungated over HTTP, LiveView or MCP.

#### Scenario: Missing netflow permission on an evidence filter
- **GIVEN** a user with `devices.view` but without `observability.netflow.view`
- **WHEN** the user runs `in:exposure contacted_threat:true time:last_24h`
- **THEN** SRQL refuses the query with a permission error
- **AND** `in:exposure cve:CVE-2024-0001` still succeeds for that user

#### Scenario: Alias does not bypass the gate
- **WHEN** a user without `observability.netflow.view` runs `in:contacts time:last_1h`
- **THEN** SRQL refuses the query with a permission error

### Requirement: SRQL Exposure Query Bounds And Failure Fidelity
Exposure entities SHALL parameterize every user-supplied value, SHALL enforce the standard limit and cursor ceilings, and SHALL cap evidence and discrepancy windows at 90 days. Exposure entities SHALL return `starrocks_required` when StarRocks is disabled. A timeout, a catalog failure or a backend failure SHALL be returned as an error, or as a field-level unavailable state, and SHALL NOT be rendered as an empty result. The SRQL parity inventory SHALL record the exposure entities as StarRocks-only.

#### Scenario: Backend timeout is not an empty result
- **GIVEN** the warehouse times out on an exposure query
- **WHEN** the client receives the response
- **THEN** it is an error that names the entity
- **AND** it is not a zero-row success

#### Scenario: StarRocks disabled
- **GIVEN** StarRocks is disabled
- **WHEN** a client runs `in:observed_connections time:last_1h`
- **THEN** SRQL returns `starrocks_required`
