# causal-prediction-signals Specification (delta for add-causal-engine)

This delta adds the verdict-emission spine for the DeepCausality causal engine
(see `causal-engine`). The engine's value is AUTOMATION: reasoning verdicts MUST
re-enter the alerting/state loop, not merely paint a topology graph. The
God-View render is one optional consumer (see `topology-god-view`). Verdicts are
published on `signals.causal.*`, which `observability-signals` already routes;
the inbound normalization path exists today, so only the PRODUCER half is new.

## ADDED Requirements

### Requirement: Verdict Emission Contract
The causal engine SHALL emit reasoning verdicts through a NEW producer that
publishes to NATS JetStream on subjects `signals.causal.predictions.{device_uid}`
for device-scoped verdicts and `signals.causal.predictions.{incident_id}` for
incident-scoped verdicts. Each verdict MUST be wrapped in an OCSF event envelope
consistent with the `signals.causal.*` prefix that `observability-signals`
already normalizes. Each verdict MUST carry a DETERMINISTIC prediction ID derived
solely from the verdict's stable inputs (e.g., the canonical `sr:`-prefixed
subject ID, the causaloid identifier, and the reasoning tick / snapshot revision),
so that re-reasoning over identical inputs produces the identical prediction ID.
Re-emission of a verdict with an unchanged prediction ID SHALL be idempotent: it
MUST NOT create a duplicate downstream event, alert, or render node, and MAY only
update the existing verdict in place. The producer MUST reuse the canonical entity
IDs validated at ingestion (see `causal-engine`) and MUST NOT invent a parallel ID
space.

#### Scenario: Device-scoped verdict published to JetStream
- **WHEN** the reasoner produces a verdict scoped to a device
- **THEN** the producer SHALL publish an OCSF-enveloped message to `signals.causal.predictions.{device_uid}`
- **AND** `{device_uid}` SHALL be the canonical `sr:`-prefixed device identifier used by the engine

#### Scenario: Incident-scoped verdict published to JetStream
- **WHEN** the reasoner produces a verdict scoped to an incident rather than a single device
- **THEN** the producer SHALL publish an OCSF-enveloped message to `signals.causal.predictions.{incident_id}`

#### Scenario: Deterministic prediction ID is stable across ticks
- **GIVEN** two reasoning ticks over identical stable inputs for the same subject and causaloid
- **WHEN** the producer derives the prediction ID for each verdict
- **THEN** both ticks SHALL produce the identical prediction ID

#### Scenario: Idempotent re-emit does not duplicate
- **GIVEN** a verdict with prediction ID `P` has already been published and normalized
- **WHEN** the producer re-emits a verdict with the same prediction ID `P`
- **THEN** the system SHALL NOT create a duplicate event, alert, or render node
- **AND** it MAY update the existing verdict in place

### Requirement: Automation Loop Closure
Published verdicts SHALL re-enter the platform automation loop without any new
inbound plumbing. The existing `CausalSignals` processor
(`elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex`)
SHALL normalize `signals.causal.predictions.*` messages into `ocsf_events` exactly
as it already does for the `signals.causal.>` prefix, and `pipeline.ex` SHALL route
the prefix to the `bmp_causal` batcher as it does today. After insertion the
normalized events SHALL be evaluated by
`StatefulAlertEngine.evaluate_events/1`
(`elixir/serviceradar_core/lib/serviceradar/observability/stateful_alert_engine.ex`),
the same seam invoked by other event writers, so that verdicts can drive alerts
and durable rule state. The engine MUST NOT bypass this seam by writing directly
to `monitoring.alerts`.

#### Scenario: Verdict normalized into ocsf_events
- **WHEN** a `signals.causal.predictions.*` message is consumed from JetStream
- **THEN** the `CausalSignals` processor SHALL normalize it into an `ocsf_events` row
- **AND** the row SHALL preserve the deterministic prediction ID for idempotency

#### Scenario: Normalized verdict re-enters the alert engine
- **GIVEN** a verdict has been normalized into `ocsf_events`
- **WHEN** the event-writer insert path completes
- **THEN** the normalized events SHALL be passed to `StatefulAlertEngine.evaluate_events/1`
- **AND** alert and durable rule-state transitions SHALL follow the existing stateful-alert lifecycle

#### Scenario: No direct alert writes
- **WHEN** the engine wants to raise an alert from a verdict
- **THEN** it SHALL do so only by emitting a verdict that flows through normalization and the alert engine
- **AND** it SHALL NOT write directly to `monitoring.alerts`

### Requirement: Device-Scoped Alerting
Verdict OCSF envelopes SHALL populate the canonical device identifier in the
group position that the stateful alert engine reads for grouping, so that
`StatefulAlertEngine.build_group/2` can group by the dotted key `device.uid`.
This delta SHALL author at least one `stateful_alert_rule` configured with
`group_by ["device.uid"]` targeting causal-prediction events, closing the loop
from verdict to a device-scoped alert. The `device.uid` value MUST equal the
canonical `sr:`-prefixed device identifier (`ocsf_devices.uid` ==
AGE `Device.id` == `ocsf_events.device.uid`) so grouping aligns with the
identity contract in `causal-engine`.

#### Scenario: Verdict envelope carries groupable device.uid
- **WHEN** a device-scoped verdict is normalized into `ocsf_events`
- **THEN** the envelope SHALL place the canonical device id at the `device.uid` group position
- **AND** the value SHALL equal the canonical `sr:`-prefixed device identifier

#### Scenario: Rule groups causal verdicts by device.uid
- **GIVEN** a `stateful_alert_rule` with `group_by ["device.uid"]` targeting causal-prediction events
- **WHEN** verdicts for the same device exceed the rule's threshold within its window
- **THEN** the engine SHALL create or update an alert grouped to that device
- **AND** verdicts for a different `device.uid` SHALL be evaluated as a separate group

### Requirement: Vulnerability Finding Emission
The engine SHALL emit an OCSF Vulnerability Finding event with `class_uid` 2004
when a verdict is driven by per-device risk supplied through the inventory risk
feed (see `inventory-risk-feed`). The finding MUST populate `device.uid` with
the canonical `sr:`-prefixed device identifier so it groups and renders under the
correct device. If the resolved `device_uid` is nil, the finding SHALL be
suppressed (not emitted) rather than published with a missing or placeholder
identity. Package-to-CVE coordinate matching is out of scope here; this engine
ONLY consumes per-device risk (e.g., `ocsf_devices.risk_score`) as established by
`inventory-risk-feed`.

#### Scenario: Vulnerability finding emitted with device.uid
- **GIVEN** a verdict driven by inventory risk for a device with a resolved canonical id
- **WHEN** the engine emits the finding
- **THEN** it SHALL be an OCSF event with `class_uid` 2004
- **AND** `device.uid` SHALL be populated with the canonical `sr:`-prefixed device identifier

#### Scenario: Finding suppressed when device_uid is nil
- **GIVEN** a verdict whose resolved `device_uid` is nil
- **WHEN** the engine considers emitting a vulnerability finding
- **THEN** it SHALL suppress the finding
- **AND** it SHALL NOT publish an event with a missing or placeholder device identity

### Requirement: God-View Render Mapping
Verdicts SHALL map cleanly to the God-View four causal buckets
`root_cause | affected | healthy | unknown` (see `topology-god-view`) without
altering the existing snapshot contract. Mapping a verdict to a bucket SHALL be
deterministic for a given verdict state. This delta SHALL NOT change the
`GodViewSnapshot` `schema_version` (which remains `2`) and SHALL NOT add or remove
buckets. Verdicts that resolve to a canonical device id which the render layer has
summarized into an endpoint-cluster summary node MUST still be classifiable; a
verdict on a summarized device id SHALL NOT silently fail to render (it MUST map to
the cluster summary node or fall to `unknown`), consistent with the identity
handling in `causal-engine`.

#### Scenario: Verdict maps to a render bucket
- **WHEN** a normalized verdict is consumed by the God-View render path
- **THEN** it SHALL map to exactly one of `root_cause | affected | healthy | unknown`
- **AND** the mapping SHALL be deterministic for that verdict state

#### Scenario: Snapshot schema version unchanged
- **WHEN** verdicts are rendered into a God-View snapshot
- **THEN** the `GodViewSnapshot` `schema_version` SHALL remain `2`
- **AND** the four-bucket set SHALL NOT be extended or reduced

#### Scenario: Verdict on a summarized device id still classifies
- **GIVEN** a verdict whose canonical device id was summarized into an endpoint-cluster summary node
- **WHEN** the render layer classifies the verdict
- **THEN** the verdict SHALL map to the cluster summary node or fall to `unknown`
- **AND** it SHALL NOT silently fail to render
