# telemetry-tiering — spec deltas

## ADDED Requirements

### Requirement: Cold-tier behavior activates only on deployment-supplied configuration
All tiered-offload behavior SHALL key off deployment-supplied cold-tier configuration (object-store location and credentials, analytics-head connection, per-table windows). When that configuration is absent, the system SHALL behave exactly as it does today: no exporter scheduling, unmodified retention policies, no cold query routing, and no analytics-head deployment.

#### Scenario: Configuration absent
- **WHEN** a deployment provides no cold-tier configuration
- **THEN** retention policies, `drop_chunks` behavior, SRQL routing, and Helm rendering are byte-identical to current behavior
- **AND** no cold-tier jobs are scheduled and no new external connections are attempted

#### Scenario: Configuration present
- **WHEN** cold-tier configuration is supplied for a set of registry tables
- **THEN** the export pipeline, retention gating, and cold query surface activate for exactly those tables

### Requirement: Cold schema registry is the single source of truth for offloaded tables
The system SHALL maintain a cold schema registry defining, per offloadable table: the export column list with canonical type casts, the object-store partition layout, per-table hot and cold windows, update-prone classification, and the analytics-head view definition. Export jobs, retention gating, view generation, and SRQL cold eligibility SHALL all derive from the registry. Schema migrations that alter a registry table SHALL fail continuous integration unless the registry entry is updated in the same change.

#### Scenario: Registry drives all cold-tier surfaces
- **WHEN** a table is added to the registry
- **THEN** its chunks become export-eligible, its retention becomes offload-gated, its analytics-head view is generated, and its SRQL entity becomes cold-eligible, with no per-surface hand-wiring

#### Scenario: Schema drift is caught in CI
- **WHEN** a migration adds or alters a column on a registry table without updating the registry entry
- **THEN** continuous integration fails before merge

### Requirement: Chunks are exported to object storage before retention may drop them
For registry tables on a cold-configured deployment, the system SHALL export closed time-chunks to immutable, hive-partitioned Parquet objects on the deployment's object store, verify each export (row count and checksum against the source chunk), and record it in a manifest table on the primary database. Object keys SHALL be deterministic so re-export is idempotent. Exported objects SHALL NOT be considered readable by any consumer until their manifest entry is verified.

#### Scenario: Routine export
- **WHEN** a chunk's end timestamp is older than the configured export lag
- **THEN** the exporter writes its rows as Parquet to the deployment bucket, verifies row count and checksum, and commits a verified manifest entry

#### Scenario: Failed verification
- **WHEN** verification of an exported object fails
- **THEN** the manifest entry is not marked verified, the chunk remains ineligible for drop, and the export is retried idempotently

### Requirement: A per-table cold completeness frontier bounds all tier transitions
The system SHALL maintain, per registry table, a cold completeness frontier: a timestamp below which all rows are verified-durable in object storage. The frontier SHALL advance only over contiguously verified chunks. The boundary value used by the cold query surface SHALL satisfy, at all times: drop point ≤ query boundary ≤ frontier — enforced by ordering (the analytics head acknowledges a boundary update before any chunk at or below it becomes drop-eligible).

#### Scenario: Frontier blocks on a gap
- **WHEN** one chunk's export fails while later chunks verify successfully
- **THEN** the frontier does not advance past the failed chunk
- **AND** no chunk above the frontier is dropped, so no time range can exist in neither tier

#### Scenario: Analytics head unreachable
- **WHEN** the analytics head cannot acknowledge a boundary update
- **THEN** drop eligibility stalls (data is held hot) rather than advancing past the boundary the query surface can see

### Requirement: Retention is offload-gated with drop-time re-verification
When the cold tier is configured, the system SHALL drop a registry-table chunk only if: (1) the chunk lies entirely at or below the acknowledged query boundary, (2) its manifest entry is verified, and (3) a drop-time re-verification against the live chunk passes — with automatic re-export on mismatch before dropping. Tables classified update-prone in the registry SHALL be re-exported unconditionally at drop time. The overlap window between export and drop SHALL be refreshed periodically so late-arriving rows and in-place updates are re-captured, and the residual staleness bound SHALL be documented as a product contract.

#### Scenario: Late-arriving rows before drop
- **WHEN** rows are inserted into an already-exported chunk before it is dropped
- **THEN** drop-time re-verification detects the drift and re-exports the chunk before dropping it

#### Scenario: Update-prone table at drop time
- **WHEN** an update-prone table's chunk reaches its drop point
- **THEN** the chunk is re-exported regardless of count match, so upserted row content is captured

#### Scenario: Writes below the drop boundary
- **WHEN** a write recreates a chunk for a time range that was already dropped
- **THEN** the standard export→verify→drop cycle picks up the recreated chunk as a new object without overlapping previously archived rows

### Requirement: Retention policy installation is fenced through a single shared helper
All installation of time-based retention policies for registry tables — by the retention worker AND by database migrations — SHALL go through a shared fence-aware helper. On cold-configured deployments the helper SHALL remove (not install) in-database retention policies for registry tables, so no autonomous background process can drop un-exported chunks. The exporter SHALL assert on each run that no in-database retention policy exists on registry tables and alert if one appears. Disabling the cold tier SHALL be a two-phase operation: held chunks are exported or explicitly waived by an operator before policies are re-armed.

#### Scenario: Upgrade re-runs retention migrations
- **WHEN** a release upgrade executes migrations that (re)install retention policies
- **THEN** policies for registry tables on a cold-configured deployment are not re-armed, and un-exported chunks survive the upgrade

#### Scenario: Cold tier disabled with held chunks
- **WHEN** an operator disables the cold tier while un-exported chunks are held
- **THEN** retention policies are not re-armed until the held chunks are exported or explicitly waived

### Requirement: Export stalls degrade with bounded pressure, never silent loss or unbounded growth
The system SHALL compute a headroom budget from ingest rate and provisioned volume, alert at escalating thresholds as held data consumes it, quarantine chunks that repeatedly fail export (skip-and-alert, blocking frontier advance but not other tables), and support an operator-acknowledged emergency drop of oldest held chunks at a hard disk watermark. The default posture SHALL be hold-and-alert; automatic dropping of un-exported data SHALL never occur without explicit operator action.

#### Scenario: Analytics head down for days
- **WHEN** exports stall and held chunks consume the headroom budget
- **THEN** escalating alerts fire at configured thresholds before the primary volume is at risk

#### Scenario: Poison chunk
- **WHEN** a chunk fails export more than the configured attempt limit
- **THEN** it is quarantined with an alert, other tables' exports continue, and a documented break-glass export path exists for it

#### Scenario: Emergency floor
- **WHEN** the primary volume crosses the hard disk watermark with un-exported chunks held
- **THEN** an operator-acknowledged forced drop of the oldest held chunks is available, and the action is logged and alerting

### Requirement: A dedicated analytics head serves the cold tier; the primary is untouched
Cold-tier execution (chunk export, Parquet reads, hot∪cold stitching) SHALL run on a dedicated analytics PostgreSQL instance that does not load TimescaleDB, deployed separately from the primary cluster. The primary database's image, extension set, shared_preload_libraries, and configuration SHALL NOT change. The analytics head SHALL access the primary only through a dedicated read-only role restricted to registry tables and the manifest, with bounded connection counts, role-level statement and idle-transaction timeouts, and TCP keepalives.

#### Scenario: Analytics head crash
- **WHEN** a cold-tier query or export crashes the analytics head
- **THEN** the primary database and all hot-path product behavior are unaffected

#### Scenario: Export load on the primary
- **WHEN** exports or cold queries read hot rows from the primary
- **THEN** they use the read-only role with pinned connection limits and timeouts, and backfill paces one chunk at a time with a transaction-age abort threshold

### Requirement: Cold reads stitch tiers without gaps or duplicates
The analytics head SHALL expose, per registry table, a schema-matched relation that unions archived Parquet (rows strictly below the query boundary) with recent hot rows read from the primary (rows at or above the boundary). Overlap-zone consistency SHALL be eventual with a documented bound: late rows and updates appear on the cold path after the next refresh pass, and no committed row is absent from both branches.

#### Scenario: Query spanning the boundary
- **WHEN** a query's window spans the query boundary
- **THEN** each row is returned exactly once, from exactly one branch, per the half-open boundary rule

#### Scenario: Late row in the overlap zone
- **WHEN** a row arrives with a timestamp below the boundary after that range was exported
- **THEN** it is visible to hot-window queries immediately and to the cold path after the next overlap refresh, within the documented bound

### Requirement: Cold tier failures degrade to hot-only results with explicit truncation
When the analytics head or object store is unavailable, queries that would use the cold tier SHALL degrade to hot-only execution and carry an explicit truncation indication to the caller. The hot path SHALL never fail because the cold tier is unavailable.

#### Scenario: Head down during a long-lookback query
- **WHEN** a query requests a window reaching below the hot window while the analytics head is unreachable
- **THEN** the hot portion of the result is returned with an explicit indication that archived history was unavailable

### Requirement: Cold data is pruned by per-table windows with manifest-first hygiene
Archived objects SHALL be pruned according to per-table cold windows from deployment configuration. Pruning SHALL delete objects before manifest rows, and a periodic reconciliation sweep SHALL detect and resolve manifest/bucket divergence, including orphaned multipart uploads.

#### Scenario: Cold window expiry
- **WHEN** archived objects age beyond the table's cold window
- **THEN** the objects are deleted, then their manifest rows, and the table's measured oldest-available timestamp updates

#### Scenario: Reconciliation finds divergence
- **WHEN** the sweep finds a manifest row without objects, or objects without manifest rows
- **THEN** the divergence is repaired (re-export or manifest cleanup) and surfaced in telemetry

### Requirement: Continuous aggregates remain correct across retention and offload
Materialized continuous-aggregate history SHALL NOT be destroyed by retention or offload activity. Because dropping raw chunks plants invalidation-log entries that any covering refresh consumes by recomputing buckets from now-absent raw (verified on TimescaleDB 2.24), every continuous aggregate's refresh window SHALL be clamped strictly inside its raw source's retention window. The system SHALL detect and alert on any aggregate whose refresh window reaches its source's retention boundary, and on pending invalidation-log entries older than the hot boundary.

#### Scenario: Raw drop leaves aggregates intact
- **WHEN** retention or offload drops raw chunks for a period with materialized aggregate buckets
- **THEN** those buckets remain readable and no policy refresh recomputes them from absent raw

#### Scenario: Hazardous refresh window detected
- **WHEN** a continuous aggregate's refresh window reaches at or past its raw source's retention (from in-database policies or, for offloaded tables, the configured hot window)
- **THEN** the retention worker raises an alert identifying the aggregate and both windows

#### Scenario: Pending stale invalidations detected
- **WHEN** invalidation-log entries older than a table's hot boundary exist
- **THEN** an alert identifies the table so operators know a covering refresh would delete materialized history

### Requirement: Storage and retention telemetry is exported for external metering
The runtime SHALL export per-registry-table storage telemetry — hot bytes, ingest bytes/day, and a non-telemetry baseline size — on its existing metrics endpoint regardless of cold-tier state. The ingest rate SHALL be derived so that retention drops and offload cannot depress it (a table shrinking must never read as negative ingest). On cold-configured deployments it SHALL additionally export cold bytes, frontier lag, held/quarantined chunk counts, headroom consumption, and the measured oldest-available timestamp per table.

#### Scenario: External control plane meters a deployment
- **WHEN** an external system scrapes the runtime metrics endpoint
- **THEN** it can compute per-signal storage usage, measured lookback, and projected horizons without direct database access

#### Scenario: Cold tier not configured
- **WHEN** no cold-tier configuration is present
- **THEN** hot-size and ingest-rate gauges are still exported and no cold-tier gauges appear

#### Scenario: Retention drops data while ingest continues
- **WHEN** retention or offload removes chunks from a table that is still ingesting
- **THEN** the exported ingest rate continues to reflect arriving data and does not fall or go negative because the table shrank
