## ADDED Requirements

### Requirement: Endpoint Inventory Collection Is Policy Controlled
The system SHALL collect endpoint software inventory only when an agent has an effective endpoint inventory policy that explicitly enables collection.

#### Scenario: Collection disabled by default
- **GIVEN** an agent has no endpoint inventory policy
- **WHEN** the agent resolves its configuration
- **THEN** no endpoint inventory collector SHALL run
- **AND** no package inventory or SBOM artifact SHALL be uploaded

#### Scenario: OS package inventory enabled
- **GIVEN** an agent has an endpoint inventory policy with OS package inventory enabled
- **WHEN** the scheduled inventory scan runs
- **THEN** the collector SHALL inspect supported local package databases
- **AND** it SHALL emit package names, versions, architecture, package manager source, and available package identifiers into the scan result

#### Scenario: Optional sources remain disabled
- **GIVEN** an endpoint inventory policy enables OS packages only
- **WHEN** the collector runs
- **THEN** it SHALL NOT collect language manifests, listening services, executable paths, or file hashes
- **AND** those sources SHALL require separate policy flags

### Requirement: Endpoint SBOM Artifacts Use CycloneDX JSON
The system SHALL generate and ingest endpoint SBOM artifacts in CycloneDX JSON format as the supported endpoint SBOM format.

#### Scenario: Collector produces valid SBOM
- **GIVEN** endpoint inventory collection is enabled for an agent
- **WHEN** the collector completes successfully
- **THEN** it SHALL write a CycloneDX JSON SBOM artifact
- **AND** the artifact SHALL include collector identity, scan timestamp, component list, package identifiers when available, and redaction metadata

#### Scenario: Unsupported SBOM format rejected
- **GIVEN** an agent attempts to upload an endpoint SBOM artifact in an unsupported format
- **WHEN** ingestion validates the artifact
- **THEN** the artifact SHALL be rejected
- **AND** the previous successful inventory state SHALL remain current

### Requirement: Endpoint Inventory Uses Deterministic Local State Hashes
The system SHALL compute deterministic endpoint inventory hashes so scheduled scans can distinguish changed and unchanged package state before uploading full artifacts or package rows.

#### Scenario: Package set hash is stable
- **GIVEN** two scans report the same normalized packages in different discovery order
- **WHEN** the agent computes the package-set hash
- **THEN** both scans SHALL produce the same package-set hash
- **AND** the hash SHALL be based on normalized package identity fields rather than raw JSON ordering

#### Scenario: Unchanged scan skips full upload
- **GIVEN** an agent has a previous successful endpoint inventory upload with package-set hash `H`
- **AND** a new scheduled scan produces package-set hash `H`
- **WHEN** the agent reports the scan result
- **THEN** it SHALL send scan status, source summaries, counts, freshness, and hash metadata
- **AND** it SHALL NOT upload the full SBOM artifact or normalized package rows unless the reconcile-floor interval is reached or an authorized force-fresh-scan command is received

#### Scenario: Changed scan uploads new inventory
- **GIVEN** an agent has a previous successful endpoint inventory upload with package-set hash `H1`
- **AND** a new scheduled scan produces package-set hash `H2`
- **WHEN** the agent reports the scan result
- **THEN** it SHALL upload the changed SBOM artifact and normalized package rows
- **AND** ingestion SHALL make the changed scan current only after artifact and package-row validation succeeds

### Requirement: Endpoint Inventory Is Normalized For Asset Queries
The system SHALL normalize changed endpoint package and component data into queryable rows linked to the reporting agent and resolved device asset.

#### Scenario: Package rows linked to asset
- **GIVEN** an agent uploads a valid endpoint SBOM artifact
- **WHEN** ingestion normalizes the artifact
- **THEN** package/component rows SHALL be linked to the agent ID, scan ID, and resolved device UID when available
- **AND** rows SHALL include package manager, ecosystem, name, version, architecture, PURL, CPE values, supplier, license, and source evidence where available

#### Scenario: Latest successful scan becomes current
- **GIVEN** a device has an existing current endpoint inventory scan
- **WHEN** a newer valid scan is ingested and normalized successfully
- **THEN** the newer scan SHALL become the current inventory for that agent/device
- **AND** the prior scan SHALL remain historical until retention removes it

#### Scenario: Latest unchanged scan updates freshness only
- **GIVEN** a device has an existing current endpoint inventory scan with package-set hash `H`
- **WHEN** a newer successful scan reports the same package-set hash `H`
- **THEN** ingestion SHALL update freshness, source summary, and unchanged scan metadata
- **AND** it SHALL NOT delete and recreate the current package/component rows

#### Scenario: Failed scan does not replace current inventory
- **GIVEN** a device has an existing current endpoint inventory scan
- **WHEN** a newer scan fails validation or normalization
- **THEN** the failed scan SHALL be recorded as failed
- **AND** the existing current inventory SHALL remain unchanged

### Requirement: Endpoint Inventory Retains Provenance
The system SHALL preserve provenance for endpoint inventory scans and artifacts so operators can explain how package data was collected.

#### Scenario: Operator inspects scan metadata
- **GIVEN** endpoint inventory exists for an asset
- **WHEN** an operator views the scan metadata
- **THEN** ServiceRadar SHALL expose scan ID, agent ID, collector version, scan start/end timestamps, enabled sources, package-set hash, artifact digest, artifact size, upload reason, and ingestion status

#### Scenario: Historical scan expires
- **GIVEN** endpoint inventory retention is configured
- **WHEN** a scan and its raw artifact exceed the retention window
- **THEN** ServiceRadar SHALL remove or compact the historical data according to policy
- **AND** it SHALL NOT delete the current inventory unless that inventory also exceeds a configured current-state retention policy

### Requirement: Endpoint Inventory Applies Privacy Bounds
The system SHALL bound endpoint inventory data collection and redact privacy-sensitive values unless explicitly enabled.

#### Scenario: Paths are redacted by default
- **GIVEN** executable or language manifest collection is enabled without path collection
- **WHEN** the collector emits component evidence
- **THEN** local filesystem paths SHALL be omitted or redacted
- **AND** package identity fields SHALL remain available for inventory queries

#### Scenario: Artifact exceeds size limit
- **GIVEN** a collector writes an endpoint SBOM artifact larger than the configured maximum
- **WHEN** the agent validates the local artifact before upload
- **THEN** the agent SHALL reject the artifact locally
- **AND** it SHALL report the scan as failed with a bounded error message

### Requirement: Endpoint Inventory Supports On-Demand Live Queries
The system SHALL support bounded on-demand endpoint software queries against connected agents through the existing agent-gateway command bus.

#### Scenario: Live package query returns compact matches
- **GIVEN** an operator submits an on-demand endpoint inventory query for package `nginx`
- **AND** targeted agents are connected and advertise endpoint inventory capability
- **WHEN** the gateway dispatches the query command
- **THEN** each agent SHALL evaluate the predicate against its local last-known-good inventory cache
- **AND** it SHALL return compact match results including agent ID, device UID when known, package-set hash, scan timestamp, match count, and matched package identities

#### Scenario: Live query does not force full upload
- **GIVEN** an on-demand endpoint inventory query can be answered from an agent's local cache
- **WHEN** the agent returns matching package identities
- **THEN** the agent SHALL NOT upload a full SBOM artifact or full package table as part of the query response
- **AND** the operator MAY request full artifact upload separately for selected agents

#### Scenario: Fresh scan requires authorization and policy support
- **GIVEN** an on-demand endpoint inventory query requests a fresh scan
- **WHEN** the targeted agent receives the command
- **THEN** the agent SHALL run the scan only if endpoint inventory policy allows the requested sources
- **AND** the command requester is authorized for fresh collection
- **AND** the scan SHALL still enforce size, source, TTL, and redaction bounds

#### Scenario: Offline agent uses persisted state or reports unavailable
- **GIVEN** an on-demand endpoint inventory query targets an offline agent
- **WHEN** the command is submitted
- **THEN** the live command SHALL fail fast for that agent through the command lifecycle
- **AND** the UI/API MAY show the latest persisted inventory state separately with its freshness timestamp

### Requirement: Endpoint Inventory Hash Canonicalization Is Pinned And Versioned
The system SHALL compute the package-set hash from a pinned canonical encoding and SHALL detect agent/collector hash errors server-side so the upload gate cannot silently degrade or be poisoned.

#### Scenario: Canonicalization excludes volatile metadata
- **GIVEN** two scans of an unchanged host produce CycloneDX artifacts that differ only in BOM serial number, BOM timestamp, JSON key order, or CPE enrichment
- **WHEN** the agent computes the package-set hash
- **THEN** both scans SHALL produce the same package-set hash
- **AND** the hash SHALL be computed over sorted normalized package identity fields (package manager, name, version, architecture, canonical PURL), not raw artifact bytes

#### Scenario: Hash carries an algorithm version
- **GIVEN** the package-set hash algorithm
- **WHEN** the agent emits a package-set hash
- **THEN** the hash SHALL be prefixed with an algorithm version identifier
- **AND** a change to the canonicalization algorithm SHALL be distinguishable from a change to package content

#### Scenario: Server recomputes and flags hash mismatch
- **GIVEN** an agent uploads a changed inventory with a reported package-set hash
- **WHEN** ingestion processes the changed upload
- **THEN** ingestion SHALL recompute the package-set hash from the normalized rows
- **AND** a mismatch with the agent-reported hash SHALL be recorded and surfaced as an operator-visible signal without silently dropping the inventory

#### Scenario: Reconcile floor forces periodic full upload
- **GIVEN** an agent has reported unchanged package-set hashes for longer than the configured reconcile window, measured in both elapsed time (M days) and scan count (N scans), whichever is reached first
- **WHEN** the next scan is acknowledged
- **THEN** ingestion SHALL return a reconcile-floor directive and the agent SHALL respond with a full changed-path upload regardless of hash
- **AND** the server SHALL track per-agent time-since-last-changed-upload as the backstop so a stuck or incorrect hash SHALL NOT suppress inventory beyond the reconcile window

### Requirement: Endpoint Inventory Collection Skips Unchanged Hosts
The collector SHALL avoid parsing package databases when no source database has changed since the last successful scan.

#### Scenario: Unchanged package databases skip parsing
- **GIVEN** the collector recorded the modification times of the OS package databases at the last successful scan
- **WHEN** a scheduled scan runs and no package database modification time has changed
- **THEN** the collector SHALL skip parsing and emit a lightweight unchanged status
- **AND** it SHALL NOT fork package-manager enumeration for that cycle

#### Scenario: Periodic forced full re-parse
- **GIVEN** package databases have not changed for several consecutive cycles
- **WHEN** the configured forced re-parse interval is reached
- **THEN** the collector SHALL perform a full parse regardless of modification times
- **AND** modification-time-preserving changes SHALL be detected at least every forced interval

### Requirement: Endpoint Inventory Storage Separates Current State From History
The system SHALL store current inventory for point lookups separately from historical inventory, and SHALL compute package diffs server-side. Historical scans and package events SHALL be stored in TimescaleDB hypertables (created via the `maybe_create_hypertable` convention, with compression and `add_retention_policy`); ClickHouse or another separate columnar engine is out of scope, though DuckDB MAY be added later for ad-hoc analytics.

#### Scenario: Current state holds only deduped latest rows
- **GIVEN** a device has a current endpoint inventory
- **WHEN** inventory is queried for that device
- **THEN** the current package/component rows SHALL be served from current-state tables
- **AND** unchanged scans SHALL NOT delete and recreate those rows

#### Scenario: History stored as time-series with independent retention
- **GIVEN** changed inventory scans and server-computed package add/remove events
- **WHEN** they are persisted
- **THEN** they SHALL be stored as time-partitioned history with compression and a retention policy independent of current-state retention
- **AND** "when did this package appear or disappear?" SHALL be answerable from history without retaining every unchanged scan

#### Scenario: Package diffs computed server-side
- **GIVEN** a changed inventory upload is ingested
- **WHEN** ingestion normalizes the scan
- **THEN** added, removed, and changed components relative to the previous current inventory SHALL be computed server-side and recorded as history events
- **AND** the agent SHALL NOT be required to compute diffs against a local previous-state cache

### Requirement: Endpoint Inventory Fleet Rollups Use Incremental Aggregates
The system SHALL answer fleet rollup questions from maintained current-count tables, standing-question result aggregates, or TimescaleDB continuous aggregates rather than ad hoc aggregate scans of the current package tables. Current-state tables are point-lookup and membership shaped and SHALL NOT be the substrate for fleet `GROUP BY` scans. The `endpoint_inventory_packages.cpes` column SHALL have a GIN index and the canonical PURL column SHALL be indexed so CPE and PURL predicates run as index scans.

#### Scenario: Fleet rollup served from incremental aggregate
- **GIVEN** an operator asks how many hosts have a package, version, or CPE
- **WHEN** the system answers the rollup
- **THEN** it SHALL serve the answer from an incremental fleet aggregate
- **AND** it SHALL NOT run an ad hoc full GROUP BY over the live current package rows

#### Scenario: Current count served from maintained counts
- **GIVEN** an operator asks for the current count of hosts matching a package coordinate
- **WHEN** the package coordinate exists in current inventory
- **THEN** the system SHALL answer from a maintained current-count table or standing-question aggregate
- **AND** the count SHALL be updated from package diff events rather than recomputed by scanning all current package rows

#### Scenario: Rollup includes offline hosts
- **GIVEN** some hosts with the package are currently offline
- **WHEN** a fleet rollup is computed
- **THEN** the rollup SHALL include those hosts based on their latest known inventory

#### Scenario: Indexed CPE and canonical PURL filters
- **GIVEN** a large current package table
- **WHEN** an SRQL predicate filters by CPE or canonical PURL
- **THEN** the query SHALL use the GIN index on `cpes` or the canonical PURL index
- **AND** it SHALL NOT fall back to a sequential scan of the current package rows

### Requirement: Live Endpoint Inventory Answers Carry Freshness And Coverage
Every live endpoint inventory answer SHALL carry a typed freshness verdict, and cohort answers SHALL carry a coverage envelope.

#### Scenario: Answer carries a freshness verdict
- **GIVEN** an agent answers an on-demand query from its local cache
- **WHEN** the answer is returned
- **THEN** it SHALL include a freshness verdict of fresh, stale, or unknown with the cache age and stale threshold
- **AND** a stale answer SHALL be distinguishable from a fresh answer

#### Scenario: Stale data distinguishable from no match
- **GIVEN** an on-demand query finds no matching package
- **WHEN** the answer is returned
- **THEN** "no match in fresh data", "no match in stale data", and "agent offline" SHALL be distinct outcomes

#### Scenario: Cohort answer carries a coverage envelope
- **GIVEN** a cohort on-demand query
- **WHEN** results are aggregated
- **THEN** the response SHALL report targeted, answered, offline, expired, and pending counts
- **AND** a partial cohort answer SHALL NOT be presented as complete

### Requirement: Cohort Endpoint Inventory Queries Are Bounded
Cohort and fleet on-demand queries SHALL be bounded in concurrency, size, and result scope.

#### Scenario: Cohort dispatched with bounded concurrency and cap
- **GIVEN** an operator submits a cohort on-demand query
- **WHEN** the gateway dispatches the query
- **THEN** it SHALL resolve eligible connected, capable, and authorized agents once
- **AND** dispatch SHALL use bounded concurrency rather than unbounded or strictly serial fan-out

#### Scenario: Cohort above cap rejected with fallback guidance
- **GIVEN** a cohort target set exceeds the configured cohort cap
- **WHEN** the query is submitted
- **THEN** the live cohort query SHALL be rejected
- **AND** the operator SHALL be directed to SRQL/persisted state or fleet aggregates

#### Scenario: Results scoped to a per-command topic
- **GIVEN** a cohort on-demand query with a query ID
- **WHEN** agents return results
- **THEN** results SHALL be delivered on a per-command result topic for that query
- **AND** a requester SHALL NOT receive another command's results

#### Scenario: Count mode is default and responses are bounded
- **GIVEN** a fleet on-demand question
- **WHEN** no detail mode is requested
- **THEN** agents SHALL return compact COUNT/EXISTS responses rather than full matched detail
- **AND** no live query response SHALL carry SBOM artifact bytes

### Requirement: Endpoint Inventory Ingest Uses A Bounded Admission Queue
The system SHALL route endpoint inventory ingest through a bounded admission queue rather than inline-synchronous processing, so correlated mass change degrades gracefully.

#### Scenario: Correlated mass change is back-pressured
- **GIVEN** a fleet-wide change causes many agents to upload changed inventory at nearly the same time
- **WHEN** ingest admission reaches its bound
- **THEN** further uploads SHALL be back-pressured or deferred rather than processed inline
- **AND** the database SHALL NOT be driven by an unbounded synchronized ingest burst

#### Scenario: Queue saturation returns a defer status
- **GIVEN** the ingest admission queue is at capacity
- **WHEN** a new upload arrives
- **THEN** ingestion SHALL return a defer/retry status rather than accept the upload synchronously

### Requirement: Endpoint Inventory Exposes Cost And Volume Observability
The system SHALL expose endpoint inventory cost and volume signals so operators can detect waste and runaway growth.

#### Scenario: Upload reason and ratio are observable
- **GIVEN** endpoint inventory is collecting across a fleet
- **WHEN** an operator inspects inventory telemetry
- **THEN** the system SHALL expose per-agent upload-reason counts (changed, unchanged, reconcile-floor, force-fresh) and the changed-vs-unchanged ratio
- **AND** sustained hash-flapping (a high changed ratio on hosts that should be stable) SHALL be detectable

#### Scenario: Storage growth is observable
- **GIVEN** endpoint inventory data is accumulating
- **WHEN** an operator inspects inventory telemetry
- **THEN** the system SHALL expose object-store bytes for SBOM artifacts, current package-row counts, and autovacuum/compression lag for inventory tables

### Requirement: Endpoint Inventory Models A Software Ontology
The system SHALL model endpoint software as first-class endpoint-side ontology entities and relationships, relationally and SRQL-queryable, so the causal engine and automations can reason over inventory.

#### Scenario: Device-package relationship is relational
- **GIVEN** a device has current endpoint inventory
- **WHEN** inventory is normalized
- **THEN** the system SHALL expose a `Device HAS_PACKAGE` relationship linking the canonical device UID to a normalized `Package` entity keyed on a canonical PURL/CPE coordinate
- **AND** the relationship SHALL be a CNPG current-state relation queryable via SRQL, NOT an AGE graph edge

#### Scenario: Package-vulnerability input modeled by feed-agnostic coordinate match
- **GIVEN** a `Package` entity with a canonical PURL/CPE coordinate
- **WHEN** an advisory from any feed references that coordinate
- **THEN** this capability SHALL provide the endpoint package coordinate input for matching on canonical PURL/CPE, with the `{package_manager, name, version, architecture}` tuple as the fallback for feeds that omit PURL
- **AND** advisory-side `Package AFFECTED_BY CVE` population, matcher policy, advisory feed, and CVSS scoring MAY be supplied by a separate change
- **AND** host-scope endpoint findings SHALL be kept distinct from image-scope scanner findings

#### Scenario: Canonical coordinate is stable and CPE-bearing
- **GIVEN** packages reported by different package managers
- **WHEN** they are normalized into `Package` entities
- **THEN** each SHALL carry a canonical PURL (per the PURL spec, computed server-side at ingest)
- **AND** the system SHALL populate candidate CPE(s) per package (derived server-side where the collector does not supply them), not only PURL, so CPE-indexed advisory feeds (e.g. VulnCheck NVD++) can match
- **AND** the canonical PURL SHALL be the primary coordinate/dedup key with the identity tuple as deterministic fallback; CPE is a co-equal match coordinate, not a substitute for PURL

#### Scenario: CPE matching is product-plus-version-range and lives in the matcher
- **GIVEN** a CPE-indexed advisory feed with version-range applicability (e.g. `versionStartIncluding`/`versionEndExcluding`)
- **WHEN** an endpoint package is matched against it
- **THEN** matching SHALL be `vendor:product` membership plus evaluation of the installed version against the advisory version range, not coordinate equality
- **AND** the PURL↔CPE normalization, version-range evaluation, and distro-backport false-positive handling SHALL live in the matcher (`add-cti-signal-coverage`), while this capability provides the indexed CPE coordinate it consumes

### Requirement: Endpoint Inventory Feeds The Causal Engine
The system SHALL feed endpoint inventory to the causal engine through the platform's standard consumption paths, keyed on canonical identity, without a bespoke transport.

#### Scenario: Inventory keyed on canonical identity
- **GIVEN** endpoint inventory rows, the device-package relation, findings, and any derived index
- **WHEN** they are persisted or indexed
- **THEN** they SHALL key on the canonical device identity (`ocsf_devices.uid`)
- **AND** the system SHALL NOT introduce a parallel inventory-only ID space, and `ocsf_events.device.uid` == `ocsf_devices` PK == AGE `Device.id` SHALL agree on one canonical string

#### Scenario: Current state and risk attributes queryable via SRQL
- **GIVEN** the causal engine hydrates its context
- **WHEN** it requests current inventory state, the device-package relation, or device risk posture
- **THEN** current-state rows and the relation SHALL be retrievable via SRQL over CNPG, and the bounded Device risk attributes via `graph_cypher` on the Device vertex
- **AND** there SHALL be no package subgraph to traverse

#### Scenario: Change events and findings published for live consumption
- **GIVEN** a changed inventory scan is ingested
- **WHEN** the server computes the package diff and any coordinate match
- **THEN** it SHALL publish package-change events and vulnerability findings through the `CausalSignals`/event-writer path into `ocsf_events`
- **AND** they SHALL be available to the engine sub-second and SRQL-queryable

#### Scenario: History excluded from CDC
- **GIVEN** the inventory history hypertable
- **WHEN** CDC/logical-replication allowlists are configured
- **THEN** the history hypertable SHALL NOT be on the CDC allowlist
- **AND** history SHALL be queried on-demand via SRQL instead

### Requirement: Endpoint Inventory Emits OCSF Vulnerability Findings
The system SHALL emit endpoint vulnerability findings as OCSF Vulnerability Findings correlatable to the canonical device.

#### Scenario: Vulnerability finding shape
- **GIVEN** an endpoint package matches an advisory coordinate
- **WHEN** the finding is emitted
- **THEN** it SHALL be an OCSF Vulnerability Finding (`class_uid=2004`) with `severity_id` mapped from CVSS, `device={"uid": <canonical device UID>}` populated directly, and the CVE and package in its grouped context
- **AND** `primary_domain` SHALL be `security`

#### Scenario: Finding suppressed without canonical identity
- **GIVEN** an inventory scan whose `device_uid` is not yet resolved
- **WHEN** a coordinate match occurs
- **THEN** the finding SHALL be suppressed rather than emitted with an empty device
- **AND** it SHALL be emitted once the canonical device UID is resolved

### Requirement: Endpoint Vulnerability Findings Are Alert-Eligible And Automatable
The system SHALL make endpoint vulnerability findings drive alerts and northbound automation without an operator viewing the topology graph.

#### Scenario: Per-device alert fires
- **GIVEN** a seeded endpoint-inventory vulnerability alert rule grouped by device
- **WHEN** a matching finding is routed
- **THEN** the alert engine SHALL evaluate it (with explicit wiring from the inventory signal path) and fire a per-device alert with the standard fired/recovered lifecycle

#### Scenario: Northbound automation triggers
- **GIVEN** a vulnerability finding is recorded
- **WHEN** it is written through the record path that drives northbound automations
- **THEN** ticket/quarantine/webhook handlers SHALL be eligible to fire on it

### Requirement: Endpoint Inventory Enriches Device Risk State
The system SHALL enrich device risk state from endpoint vulnerability findings, independent of the event path.

#### Scenario: Risk contribution recorded with MAX-wins arbitration
- **GIVEN** a device has matching endpoint vulnerabilities
- **WHEN** risk is enriched at ingest
- **THEN** the system SHALL record an `endpoint_inventory` risk contribution (CVSS-derived, bounded) and recompute device risk with MAX-wins multi-source arbitration
- **AND** the enrichment SHALL NOT be blocked for inactive/decommissioned devices, and SHALL converge when the offending package is removed

### Requirement: Endpoint Inventory Does Not Bloat The Topology Graph
The system SHALL keep package membership out of the AGE topology graph and SHALL NOT alter the canonical device identity shape.

#### Scenario: Only a bounded risk summary touches the graph
- **GIVEN** a device's endpoint risk summary changes
- **WHEN** the graph is updated
- **THEN** the system SHALL SET at most a bounded fixed set of risk-summary scalars on the EXISTING `Device` vertex
- **AND** it SHALL NOT create `Package` vertices or `HAS_PACKAGE`/`AFFECTED_BY` edges in the topology graph

#### Scenario: Membership is an index scan, not a graph traversal
- **GIVEN** a "which devices run coordinate X" query
- **WHEN** it is answered
- **THEN** it SHALL be an index scan over `endpoint_inventory_packages` (canonical PURL / GIN `cpes`)
- **AND** it SHALL NOT traverse the AGE graph

#### Scenario: Canonical device id shape is unchanged
- **GIVEN** the device identity
- **WHEN** inventory and any derived ordinal are stored
- **THEN** `ocsf_devices.uid` SHALL remain the canonical identity and SHALL NOT gain a derived-ordinal column
- **AND** any `u32` ordinal SHALL live only in a derived dictionary table and the deferred in-memory index

### Requirement: Endpoint Inventory Maintains A Stable Device Ordinal Dictionary
The system SHALL maintain a stable, dense, merge-safe `uid → u32` ordinal dictionary so a fleet inverted index can be added later without retrofitting under load.

#### Scenario: Ordinal derived from canonical uid
- **GIVEN** a confirmed device with a canonical `ocsf_devices.uid`
- **WHEN** an ordinal is allocated
- **THEN** it SHALL be a dense `u32` referencing `ocsf_devices.uid`, never reused
- **AND** a device merge SHALL tombstone the dead UID's ordinal and ensure the survivor has one

#### Scenario: Inverted index is deferred and additive
- **GIVEN** no interactive cohort/drill-down consumer exists yet
- **WHEN** fleet membership or cohort resolution is needed
- **THEN** the GIN-indexed current-state `SELECT` SHALL serve it
- **AND** the roaring inverted index MAY be built later as an in-memory, rebuildable accelerator keyed on the ordinal dictionary, consumed by neither the causal engine nor the automation pipeline
