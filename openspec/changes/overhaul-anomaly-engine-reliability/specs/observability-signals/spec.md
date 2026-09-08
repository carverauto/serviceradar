# observability-signals (delta)

## ADDED Requirements

### Requirement: Anomaly signal classification is single-path

All anomaly-shaped payloads (carrying an anomaly block or an anomaly event type) SHALL be classified through the anomaly Detection Finding builder and its confirmation gate regardless of the payload's `signal_type` value, including legacy values. No anomaly payload SHALL reach an alternate event-row builder that bypasses confirmation gating or severity clamping.

#### Scenario: Legacy causal-typed anomaly payload is gated
- **GIVEN** an anomaly payload with `signal_type` "causal" and a pending detector state
- **WHEN** the EventWriter processes it
- **THEN** it routes through the anomaly Detection Finding builder
- **AND** the confirmation gate withholds it
- **AND** no class-1008 row is created

### Requirement: Anomaly ingest enforces episode semantics against any producer

Ingest SHALL maintain an episode registry keyed by the deterministic finding UID and episode identity. Repeated or duplicate reports for an open episode SHALL fold into the episode (occurrence accounting) without new event rows, regardless of the producer's version or emission behavior. Ingest SHALL bound persisted event rows per finding per hour, withhold payloads whose reason indicates a pending confirmation state, and clamp producer severities that violate the severity contract (edge drift above High; pending states above Low). Anomaly event payloads SHALL be stored once per row, not duplicated across metadata, unmapped, and raw_data.

#### Scenario: Per-sample re-fire storm collapses at the door
- **GIVEN** a stale addon emitting one confirmed-open report per evaluation for one series
- **WHEN** thousands of reports arrive in an hour
- **THEN** persisted rows for that finding do not exceed the hourly bound
- **AND** the folded reports are visible as episode occurrence counts and governor telemetry

#### Scenario: Severity backstop clamps a mis-graded drift report
- **GIVEN** an edge-drift payload claiming Critical severity
- **WHEN** ingest normalizes severity
- **THEN** the persisted severity does not exceed High

### Requirement: Anomaly alert pipeline liveness is verified

Seeded anomaly alert rules SHALL fire on the current confirmed-anomaly event shape, fired alerts SHALL be persisted and visible in the alerts surface, and deployments touching the anomaly pipeline SHALL be gated by an end-to-end alert liveness check (synthetic confirmed episode → rule fire → persisted alert → recovery on clear). A signal rename or event-shape change that silences the alert engine MUST be detected by this check before rollout completes.

#### Scenario: Alert liveness gate catches a silent stall
- **GIVEN** a deployment that changes the anomaly signal subject or event shape
- **WHEN** the post-deploy liveness check injects a synthetic confirmed episode
- **THEN** the seeded rule fires and a persisted alert row exists
- **AND** the rollout is blocked if either step fails

#### Scenario: Alert evaluation is bounded to transitions
- **GIVEN** an open episode receiving folded duplicate reports
- **WHEN** ingest processes them
- **THEN** only lifecycle transitions (open, severity escalation, clear) enqueue alert evaluation
