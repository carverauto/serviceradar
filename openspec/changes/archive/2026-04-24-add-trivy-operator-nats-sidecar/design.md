# Design: add-trivy-operator-nats-sidecar

## Context

Trivy Operator stores scan findings as Kubernetes CRDs. ServiceRadar currently lacks a publisher that exports those reports into JetStream.
We already have an in-repo `falcosidekick` codebase with working NATS connectivity patterns (TLS, `.creds`, auth handling, reconnect behavior) that we can reuse for implementation.

## Goals / Non-Goals

- Goals:
  - Stream Trivy Operator reports into NATS JetStream as normalized messages.
  - Preserve enough source metadata for downstream normalization and promotion workflows.
  - Keep publisher resilient to Kubernetes watch churn and NATS reconnect events.
- Non-Goals:
  - Implementing Trivy -> OCSF event mapping in this change.
  - Implementing alert promotion policy in this change.
  - Replacing Trivy Operator or modifying its scanners.

## Decisions

### 1. New Service: `trivy-sidecar`

Implement a dedicated Go binary under ServiceRadar (not a full Falcosidekick fork) that:
- Discovers supported Trivy CRDs via the Kubernetes API
- Starts watches/informers for available report kinds
- Publishes normalized envelopes to NATS

### 2. Reuse Falcosidekick NATS Connection Patterns

Adopt the same auth and TLS options already proven in `falcosidekick`:
- `NATS_HOSTPORT`
- `NATS_SUBJECT_PREFIX` (default `trivy.report`)
- `NATS_CREDSFILE` (JWT creds)
- `NATS_CACERTFILE`
- optional mTLS cert/key options

### 3. Subject Contract

Publish to low-cardinality subjects:
- `trivy.report.vulnerability`
- `trivy.report.configaudit`
- `trivy.report.exposedsecret`
- `trivy.report.rbacassessment`
- `trivy.report.infraassessment`
- cluster-scoped variants as `trivy.report.cluster.<kind>`

Resource identity details remain in payload fields, not subject tokens.

### 4. Message Envelope

Each message contains:
- `event_id`: deterministic hash over cluster id + report GVK + namespace/name + resourceVersion
- `cluster_id`
- `report_kind`, `api_version`
- `namespace`, `name`, `owner_ref` (kind/name/uid if available)
- `summary` (counts by severity/check status, when present)
- `report` (raw CRD body)
- `observed_at` (sidecar publish timestamp)

### 5. Dedupe and Replay Behavior

- Track last published `resourceVersion` per report UID; skip unchanged updates.
- On sidecar restart, informer resync may replay objects; dedupe avoids duplicate publish for unchanged revisions.
- When revision changes, publish exactly one new message.

### 6. Failure Handling

- Kubernetes watch restarts are automatic with backoff.
- NATS publish failures are retried with bounded exponential backoff.
- If a message cannot be published after retry budget, emit error metric/log and continue (non-blocking).

### 7. Deployment Model

- Deploy as a standalone pod/deployment in cluster (sidecar role for Trivy ecosystem).
- Use service account RBAC read-only on Trivy report CRDs.
- Mount NATS creds/certs from secret.

## Risks / Trade-offs

- Report churn can generate bursty publish volume.
  - Mitigation: dedupe by resourceVersion and low-cardinality subjects.
- Trivy Operator CRD set differs by version.
  - Mitigation: dynamic CRD discovery and watch only available kinds.
- Large report payloads may increase message size.
  - Mitigation: leave payload raw for now; compression/chunking can be follow-up if needed.

## Migration Plan

1. Deploy `trivy-sidecar` with NATS credentials and Trivy CRD read permissions.
2. Ensure `trivy_reports` stream exists (or configure an existing stream for `trivy.report.>`).
3. Trigger/refresh Trivy scans and confirm messages arrive on `trivy.report.>` subjects.
4. Validate reconnect/dedupe behavior by restarting sidecar and observing message counts.

Rollback: scale sidecar deployment to zero and remove stream/subjects if needed.

## Open Questions

- Should initial publish include full report JSON always, or allow optional summary-only mode for very large reports?
- Should cluster id be configured explicitly or derived from kube-system metadata by default?

