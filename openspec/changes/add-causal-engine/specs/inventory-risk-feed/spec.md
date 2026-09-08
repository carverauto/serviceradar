# inventory-risk-feed Specification (delta for add-causal-engine)

This delta authors the inventory->engine seam (umbrella decision 4): how landed
endpoint inventory contributes per-device risk into the composite device score and
how that risk reaches the DeepCausality causal engine as a normalized signal. The
engine ONLY consumes per-device risk; it performs NO package-to-CVE coordinate
matching (that lives in `add-cti-signal-coverage`). Package membership stays a CNPG
relation queryable via SRQL; the bounded graph summary is `pkg_*` risk scalars on
AGE `Device` nodes (see `age-graph`), with NO package vertices or edges. Risk
flows into reasoning via `causal-reasoning` and out via
`causal-prediction-signals`.

This delta depends on `add-endpoint-sbom-inventory` (landed
`endpoint_inventory_scans` / `_artifacts` / `_packages` tables and
`EndpointInventoryIngestor`) and on `add-cti-signal-coverage` (the source of
package-level CVE coordinate matching that resolves into per-device risk). It reuses
the landed `DeviceRiskReducer`
(`elixir/serviceradar_core/lib/serviceradar/inventory/device_risk_reducer.ex`).

## ADDED Requirements

### Requirement: Endpoint Inventory Risk Contribution
The endpoint inventory ingestion path SHALL contribute per-device risk into the
composite device score through the landed `DeviceRiskReducer` using a NEW source
identifier `endpoint_inventory`. Contributions MUST be submitted via
`DeviceRiskReducer.upsert_contribution/2` (or `upsert_contributions/2`) keyed on the
canonical `device_uid`, the source `endpoint_inventory`, and a stable `source_ref`,
and SHALL be arbitrated MAX-wins so that the highest active contribution determines
the value written to `ocsf_devices.risk_score` / `risk_level_id` / `risk_level`. A
lower `endpoint_inventory` contribution MUST NOT clobber a higher active
contribution from another source, and a lower contribution from another source MUST
NOT clobber a higher active `endpoint_inventory` contribution. The contribution
SHALL be ingestor-driven (recomputed when an inventory scan is ingested) so that
risk is maintained without depending on the device being currently active or
online; inactive devices MUST NOT be suppressed from carrying inventory risk. The
package-derived risk severity that feeds the contribution score SHALL be the
per-device risk supplied by `add-cti-signal-coverage`; this delta SHALL NOT perform
any package-to-CVE coordinate matching, PURL/CPE matching, or CVSS scoring itself.

#### Scenario: Inventory scan emits a device risk contribution
- **WHEN** an endpoint inventory scan is ingested for a device with a resolved canonical `device_uid`
- **THEN** the path SHALL call `DeviceRiskReducer.upsert_contribution/2` with source `endpoint_inventory`
- **AND** the contribution SHALL be keyed on `device_uid`, source `endpoint_inventory`, and a stable `source_ref`
- **AND** the derived composite SHALL be written to `ocsf_devices.risk_score`, `risk_level_id`, and `risk_level`

#### Scenario: MAX-wins arbitration is preserved across sources
- **GIVEN** an active contribution from another source with score 80 for a device
- **WHEN** an `endpoint_inventory` contribution with score 40 is upserted for the same device
- **THEN** the written `ocsf_devices.risk_score` SHALL remain 80
- **AND** a later `endpoint_inventory` contribution with score 90 SHALL raise the written score to 90

#### Scenario: Inactive device still carries inventory risk
- **GIVEN** a device that is not currently active or online
- **WHEN** an endpoint inventory scan for that device is ingested
- **THEN** the `endpoint_inventory` contribution SHALL still be recomputed and written
- **AND** the device SHALL NOT be suppressed from carrying inventory risk because of its activity state

#### Scenario: No CVE matching performed in this feed
- **WHEN** the contribution score is derived for an `endpoint_inventory` contribution
- **THEN** the score SHALL be taken from the per-device risk supplied by `add-cti-signal-coverage`
- **AND** this feed SHALL NOT perform package-to-CVE coordinate matching, PURL/CPE matching, or CVSS scoring

### Requirement: Inventory Causal Signal Emission
The platform SHALL emit inventory risk transitions as causal signals on subjects
under the `signals.causal.inventory.*` prefix so the causal engine can consume them
as a live feed (see `causal-reasoning`). These messages MUST be normalizable by the
existing `CausalSignals` processor
(`elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex`),
which already normalizes the `signals.causal.>` prefix into `ocsf_events`; this delta
SHALL add NO new inbound normalization plumbing. Each emitted signal MUST carry the
canonical `sr:`-prefixed `device.uid` so it aligns with the identity contract in
`causal-engine` and can group with verdicts emitted by `causal-prediction-signals`.
Emission SHALL be transition-driven (published when a device's inventory-derived risk
materially changes), not a continuous restatement of unchanged risk.

#### Scenario: Inventory risk transition published on the causal prefix
- **WHEN** a device's inventory-derived risk materially changes
- **THEN** a signal SHALL be published under `signals.causal.inventory.*`
- **AND** the message SHALL carry the canonical `sr:`-prefixed `device.uid`

#### Scenario: Signal normalized by the existing processor
- **WHEN** a `signals.causal.inventory.*` message is consumed
- **THEN** the existing `CausalSignals` processor SHALL normalize it into `ocsf_events`
- **AND** this delta SHALL add no new inbound normalization plumbing

#### Scenario: Engine consumes inventory risk as a live feed
- **GIVEN** the causal engine subscribed to the `signals.causal.>` family
- **WHEN** an inventory risk signal is normalized
- **THEN** the engine SHALL be able to consume the per-device risk as input to reasoning (see `causal-reasoning`)

### Requirement: Relational Membership Not Graph Edges
Device-to-package membership SHALL remain a CNPG relation queryable through SRQL
(over the landed `endpoint_inventory_packages` table from
`add-endpoint-sbom-inventory`) and SHALL NOT be projected as graph topology. This
delta explicitly forbids introducing `Package` vertices, `HAS_PACKAGE` edges, or
`AFFECTED_BY` edges into the AGE graph. The only graph-visible representation of
inventory risk SHALL be the bounded `pkg_*` risk scalars carried on the AGE `Device`
node, defined by `age-graph`; this keeps the graph bounded and avoids reintroducing
unbounded fanout into the reasoning topology.

#### Scenario: Membership stays a relation
- **WHEN** a consumer needs device-to-package membership
- **THEN** it SHALL query the CNPG relation (`endpoint_inventory_packages`) via SRQL
- **AND** the membership SHALL NOT be required to traverse the AGE graph

#### Scenario: No package vertices or edges in the graph
- **WHEN** inventory risk is projected for graph rendering and reasoning
- **THEN** the projection SHALL NOT create `Package` vertices
- **AND** it SHALL NOT create `HAS_PACKAGE` or `AFFECTED_BY` edges

#### Scenario: Bounded pkg_* scalars are the only graph-visible risk
- **WHEN** inventory risk must be visible on the graph
- **THEN** it SHALL be represented only as the bounded `pkg_*` risk scalars on the AGE `Device` node (see `age-graph`)
- **AND** the graph SHALL remain bounded with no per-package fanout
