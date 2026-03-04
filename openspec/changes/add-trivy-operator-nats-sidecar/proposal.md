# Proposal: add-trivy-operator-nats-sidecar

## Why

Issue #2987 asks for Trivy support by creating a Go sidecar that forwards Trivy findings into NATS JetStream.
Today Trivy Operator data remains in Kubernetes CRDs and is not flowing into ServiceRadar's ingestion pipeline, so we cannot correlate cluster vulnerability/compliance findings with logs/events/alerts.

## What Changes

- Add a new Go service (`trivy-sidecar`) that watches Trivy Operator report CRDs and publishes normalized JSON envelopes to NATS JetStream.
- Reuse proven NATS auth/TLS connection patterns from the in-repo `falcosidekick` source (JWT `.creds`, CA verification, optional mTLS).
- Publish to dedicated Trivy subjects (`trivy.report.>`) with a default JetStream stream (`trivy_reports`) to isolate retention and replay from other security signals.
- Support the Trivy report families commonly produced by the operator:
  - `VulnerabilityReport`, `ConfigAuditReport`, `ExposedSecretReport`, `RbacAssessmentReport`, `InfraAssessmentReport`
  - cluster-scoped equivalents when present
- Emit deterministic event identity/fingerprint fields and suppress duplicate publish on unchanged report revisions.
- Add sidecar metrics and health endpoints for publish success, publish failures, watch restarts, and dedupe counts.
- Document deployment + verification against a live Kubernetes cluster where Trivy Operator is installed.

## Non-Goals

- No CNPG schema changes in this change.
- No direct write from sidecar to `platform.logs`/`platform.ocsf_events`.
- No Trivy-specific UI in this change.
- No tenant/multi-cluster control plane work.

## Impact

- Affected specs: `trivy-nats-ingestion` (new capability)
- Affected systems:
  - New Go sidecar binary and packaging/deployment manifests
  - NATS JetStream subjects/stream provisioning for Trivy payloads
  - Operational docs for Trivy Operator integration
- Operational impact:
  - New security telemetry stream in NATS (`trivy.report.>`)
  - Additional NATS message volume based on Trivy report churn
- Dependencies:
  - Trivy Operator CRDs available in the target cluster
  - NATS credentials and cert material for sidecar connectivity

