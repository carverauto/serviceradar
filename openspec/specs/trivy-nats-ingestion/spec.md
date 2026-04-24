# trivy-nats-ingestion Specification

## Purpose
TBD - created by archiving change add-trivy-operator-nats-sidecar. Update Purpose after archive.
## Requirements
### Requirement: Trivy Operator reports are published to JetStream

The system SHALL publish Trivy Operator report resources to NATS JetStream subjects under `trivy.report.>` using a dedicated Trivy sidecar service.

#### Scenario: Vulnerability report is published

- **GIVEN** Trivy Operator has created a `VulnerabilityReport` resource
- **WHEN** the Trivy sidecar observes the report revision
- **THEN** it SHALL publish one JSON message to `trivy.report.vulnerability`
- **AND** the message SHALL include cluster, namespace, report identity, and raw report payload fields

#### Scenario: Cluster-scoped report is published

- **GIVEN** Trivy Operator has created a cluster-scoped report kind supported by the sidecar
- **WHEN** the sidecar observes the report revision
- **THEN** it SHALL publish one JSON message to `trivy.report.cluster.<kind>`

### Requirement: Publish identity is deterministic

The system SHALL generate deterministic event identifiers for each published report revision so downstream consumers can deduplicate safely.

#### Scenario: Stable identity for same revision

- **GIVEN** the same report revision is processed multiple times
- **WHEN** the sidecar computes `event_id`
- **THEN** the computed `event_id` SHALL be identical for each processing attempt

### Requirement: Sidecar suppresses duplicate publishes for unchanged revisions

The system SHALL suppress duplicate publishes when Kubernetes watch/informer delivery repeats an unchanged report revision.

#### Scenario: Replayed informer event is skipped

- **GIVEN** a report UID and `resourceVersion` already published
- **WHEN** the same UID and `resourceVersion` is observed again
- **THEN** the sidecar SHALL NOT publish a duplicate NATS message

#### Scenario: New revision is published

- **GIVEN** a report UID already published with an older `resourceVersion`
- **WHEN** a newer `resourceVersion` is observed
- **THEN** the sidecar SHALL publish a new NATS message for that revision

### Requirement: NATS authentication and TLS are configurable

The sidecar SHALL support NATS `.creds` authentication and CA-based TLS verification for JetStream connectivity.

#### Scenario: Sidecar connects with credentials and CA

- **GIVEN** valid `NATS_CREDSFILE` and `NATS_CACERTFILE` configuration
- **WHEN** the sidecar starts
- **THEN** it SHALL establish a NATS connection and publish messages successfully

#### Scenario: Invalid credentials fail safely

- **GIVEN** an invalid or revoked NATS credentials file
- **WHEN** the sidecar attempts to connect
- **THEN** it SHALL fail health checks and emit authentication error logs/metrics

### Requirement: Sidecar handles partial Trivy CRD availability

The sidecar SHALL discover available Trivy report CRDs at runtime and watch only those present in the cluster.

#### Scenario: Missing report kind does not crash sidecar

- **GIVEN** one or more expected Trivy report CRDs are not installed
- **WHEN** the sidecar initializes watchers
- **THEN** it SHALL continue running with remaining available report kinds
- **AND** it SHALL emit logs indicating which kinds were skipped

### Requirement: Sidecar exposes operational telemetry

The sidecar SHALL expose health and metrics needed to operate report publishing in production.

#### Scenario: Publish counters are observable

- **WHEN** the sidecar publishes, retries, deduplicates, or drops a report
- **THEN** metrics SHALL reflect those outcomes per report kind and result type
