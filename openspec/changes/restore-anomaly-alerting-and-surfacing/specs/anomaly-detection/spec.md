# anomaly-detection — deltas for restore-anomaly-alerting-and-surfacing

## ADDED Requirements

### Requirement: Production releases schedule the anomaly pipeline workers

The deployed release configuration SHALL schedule every anomaly pipeline worker the platform depends on — episode stale-close, stale-anomaly resolution, seasonal disposition, seasonal edge-baseline production, and anomaly edge config projection — with the same cadences and env gates as the library configuration, and the build SHALL carry an automated guard that fails when the release crontab and the required production worker set diverge.

#### Scenario: Release crontab contains the anomaly workers
- **WHEN** the production release boots with default configuration
- **THEN** the Oban crontab includes the episode stale-close, stale-anomaly resolution, seasonal disposition, seasonal edge-baseline, and config projection entries
- **AND** a CI-run test fails if any required production worker is missing from the release crontab

#### Scenario: Seasonal baselines get produced on a stock deployment
- **GIVEN** a stock deployment with sufficient metric history
- **WHEN** the seasonal edge-baseline producer's scheduled run completes
- **THEN** enabled anomaly addon profiles carry a `seasonal_baselines` payload with a fresh reconcile timestamp

### Requirement: Seeded alert rules are reconciled with the shipped contract

Platform-seeded stateful alert rules SHALL carry a managed marker and template version, and the seeder SHALL update managed rules whose stored contract lags the shipped template (including subject prefixes, signal/event type matchers, and lifecycle state lists), while leaving operator-modified rules untouched. A one-time migration SHALL repair existing rows still matching retired `signals.causal.*` subject prefixes.

#### Scenario: Legacy subject prefix repaired
- **GIVEN** a stored rule whose match subject_prefix is `signals.causal.predictions`
- **WHEN** the migration and seeder run
- **THEN** the rule matches findings arriving on `signals.analytics.predictions.*`

#### Scenario: Operator-modified rule preserved
- **GIVEN** a seeded rule an operator has edited away from the template
- **WHEN** the seeder reconciles managed rules
- **THEN** the operator's rule is not overwritten and the skip is logged

### Requirement: Alert rule evaluation runs only where rules can be loaded

Stateful alert engine shards SHALL NOT be silently hosted on cluster members without repository access. Non-core members (agent gateways) SHALL opt out of hosting distributed processes, and a shard that cannot load rules SHALL emit a warning and telemetry (including a per-shard loaded-rule count) rather than evaluating zero rules indefinitely.

#### Scenario: Gateway nodes host no alert shards
- **GIVEN** a cluster of core, gateway, and web nodes
- **WHEN** the engine shards are placed after a restart
- **THEN** every shard runs on a node with repository access and reports a non-zero rule count for shards owning seeded rules

#### Scenario: Repo-less shard is loud
- **WHEN** a shard finds itself without repository access
- **THEN** it logs a warning and emits telemetry identifying the shard and node

### Requirement: Anomaly episodes are recorded and surfaced by default

The episode registry SHALL be enabled by default in production (with an explicit kill switch), the episode stale-close threshold SHALL exceed the configured episode heartbeat interval by a safety margin of at least 2×, and the default device-page anomaly surface SHALL read a store that is populated under default configuration. CPU-class findings SHALL NOT be unconditionally hidden by a disposition field no producer persists.

#### Scenario: Stock deployment shows anomalies on device pages
- **GIVEN** a stock deployment where the edge detector emits open/clear transitions
- **WHEN** a user opens the device page of an affected device
- **THEN** the anomaly panel shows the episode without extra configuration

#### Scenario: Live episode survives heartbeat jitter
- **GIVEN** an open episode heartbeating at the configured update interval
- **WHEN** one heartbeat is delayed by less than the safety margin
- **THEN** the stale-close sweep does not close the episode

### Requirement: Anomaly pipeline liveness is monitored in both directions

The platform SHALL detect silent anomaly-pipeline failure, not only over-emission: a scheduled synthetic liveness check SHALL exercise the finding→alert→resolve path (including rule contract assertions) and raise an operational alert on failure; a silence tripwire SHALL raise a health event when no anomaly findings persist for a configurable period while metric ingest is alive; and baseline-delivery freshness SHALL be monitored so that drift detection inactive for lack of baselines is visibly distinct from breakage.

#### Scenario: Rename regression fails loudly
- **GIVEN** a rule-shape or subject rename regression that silently stops alert matching
- **WHEN** the scheduled liveness check next runs
- **THEN** an operational alert is raised identifying the failed stage

#### Scenario: Zero-finding silence is flagged
- **WHEN** no anomaly findings have persisted for the configured window while timeseries ingest is healthy
- **THEN** a health event is emitted

#### Scenario: Missing baselines are visible
- **WHEN** no enabled anomaly profile carries a fresh seasonal baseline payload
- **THEN** a health event is emitted and the drift-inactive-for-lack-of-baseline count is visible to operators

### Requirement: Alert staleness is judged by episode liveness

Automatic stale-anomaly alert resolution SHALL consult the episode store: an alert whose finding has an open episode with a fresh heartbeat SHALL NOT be auto-resolved, regardless of whether deduplicated re-emissions reach the alert engine.

#### Scenario: Long-lived open anomaly keeps its alert
- **GIVEN** an anomaly open for longer than the stale-resolution window whose episode heartbeats keep it open
- **WHEN** the stale-resolution sweep runs
- **THEN** the alert remains open

#### Scenario: Abandoned anomaly alert resolves
- **GIVEN** an alert whose episode is cleared, stale-closed, or absent
- **WHEN** the stale-resolution sweep runs
- **THEN** the alert is resolved

## MODIFIED Requirements

### Requirement: Operator configuration reaches the edge detector

Anomaly detection settings edited in the Settings UI SHALL be projected onto the anomaly addon profile under a reserved `managed` params sub-key so they take effect at the edge within one config poll interval, with per-metric-class knobs (mode, thresholds, floors, severity overrides, denylist, emission governance). The projection worker SHALL be scheduled and enabled by default in production releases, with an explicit kill switch; a deployment where projection is disabled SHALL surface that state wherever the settings are edited so operators know their changes are not reaching the edge. Operator-explicit top-level profile parameters SHALL take precedence over projected managed values. The config projector and baseline producer SHALL own disjoint params keys (`managed` vs `seasonal_baselines`) and SHALL preserve each other's payloads. Kill switches SHALL exist per class and globally, at the addon, projection, and ingest layers.

#### Scenario: Raising a per-class threshold changes edge behavior
- **GIVEN** an operator raising the interface-class drift confirm threshold in Settings
- **WHEN** the projector runs and the agent polls config
- **THEN** the edge detector applies the new threshold without an addon redeploy

#### Scenario: Disabled projection is visible
- **GIVEN** a deployment with the projection kill switch engaged
- **WHEN** an operator edits anomaly detection settings
- **THEN** the UI indicates that projection to the edge is disabled

### Requirement: Streaming Statistical Anomaly Detection

The system SHALL detect anomalies in live metric streams at the edge by comparing each incoming sample against a per-series learned baseline maintained in a bounded sliding window, without requiring an operator-configured static threshold. Detection SHALL use robust statistics (median-based center and MAD-derived scale with dispersion floors) so heavy-tailed series do not distort the baseline, and SHALL run per-sample against the agent-local metric feed.

#### Scenario: Anomalous sample exceeds the learned baseline
- **WHEN** a metric sample arrives for a series whose sliding window is warmed
- **THEN** the system SHALL compute a robust z-score against the window's median and floored MAD-derived scale
- **AND** SHALL flag the sample as anomalous when the score exceeds the configured N-sigma threshold

#### Scenario: Window not yet warmed
- **WHEN** a series' sliding window has fewer than the minimum required samples
- **THEN** the system SHALL NOT emit an anomaly verdict for that series and SHALL continue accumulating baseline samples

### Requirement: Restart Resilience

The edge detector SHALL survive restarts without generating spurious findings and without permanently losing detection coverage. When a checkpoint path is configured, the detector SHALL persist a compact per-series state snapshot (window samples, confirmation counters, episode state) and restore it on boot, respecting a maximum snapshot age; without a checkpoint, restarts SHALL cold-start baselines and suppress findings per series until the window re-warms to the minimum sample count. Restarts SHALL NOT fork episodes: a restored open episode continues rather than re-opening.

#### Scenario: Detector restarts with a checkpoint
- **WHEN** the addon restarts and a fresh checkpoint exists
- **THEN** it restores per-series windows, counters, and open-episode state and resumes without a warm-up gap

#### Scenario: Detector restarts without a checkpoint
- **WHEN** the addon restarts with no (or an expired) checkpoint
- **THEN** it suppresses findings per series until the minimum sample count re-accumulates

## REMOVED Requirements

### Requirement: Baseline Cold-Start from Aggregated History
**Reason**: Described the deleted central detector seeding windows from TimescaleDB continuous aggregates; the edge addon has no database access and cold-starts from the live feed with optional checkpoint restore.
**Migration**: Restart behavior is contracted by the modified "Restart Resilience" requirement (checkpoint restore or bounded re-warm silence).

### Requirement: Stateless Reasoning with Externalized Context
**Reason**: Described the deleted central Horde-owned per-series context engine; no such component exists (detection state lives in the edge addon process).
**Migration**: None — superseded by edge-local state plus the episode registry at ingest.

### Requirement: Horizontal Scaling via Cluster Replicas
**Reason**: Described scaling the deleted central detection engine across cluster replicas; detection now scales with the agent fleet.
**Migration**: None.

### Requirement: DeepCausality Authoritative Reasoner
**Reason**: The central `CausalReasoner` NIF was deleted with move-anomaly-detection-to-edge; only the `anomaly_disposition` NIF (seasonal/capacity kernels) remains.
**Migration**: Central numeric kernels are covered by the seasonal/capacity requirements in this spec and the capacity-forecasting spec.

### Requirement: Incremental Rolling Reasoner State
**Reason**: Implementation contract (Welford O(1) updates) for the deleted central reasoner.
**Migration**: None — edge detector state is contracted behaviorally, not by implementation.

### Requirement: Batched Reasoner Entry Point
**Reason**: API contract (`reason_batch`, DirtyCpu) for the deleted central reasoner NIF.
**Migration**: None.

### Requirement: Native Shard Runtime State
**Reason**: Shard-state contract for the deleted central reasoner runtime.
**Migration**: None.

### Requirement: Parity and Cleanup Gate
**Reason**: One-time migration gate for replacing the hand-rolled evaluator with the (since deleted) central DeepCausality reasoner; the gate completed and both sides of the parity comparison no longer exist.
**Migration**: None.
