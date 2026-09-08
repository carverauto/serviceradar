# Tasks: add-trivy-operator-nats-sidecar

## 1. Sidecar Foundation

- [x] 1.1 Create a new Go binary/package for `trivy-sidecar` with config loading, logger, and lifecycle handling.
- [x] 1.2 Implement Kubernetes dynamic discovery for supported Trivy report CRDs.
- [x] 1.3 Implement informer/watch wiring for discovered report kinds.

## 2. NATS Publishing

- [x] 2.1 Implement NATS connection setup using `.creds` and TLS options (aligned with Falcosidekick patterns).
- [x] 2.2 Implement subject routing by report kind under `trivy.report.>`.
- [x] 2.3 Implement deterministic envelope building and `event_id` generation.
- [x] 2.4 Implement dedupe by report UID + resourceVersion.
- [x] 2.5 Implement retry/backoff for transient publish failures.

## 3. Security and Deployment

- [x] 3.1 Add Kubernetes RBAC manifests for read-only access to Trivy report CRDs.
- [x] 3.2 Add deployment/Helm values for sidecar image, env vars, and mounted NATS creds/certs.
- [x] 3.3 Ensure default stream/subject expectations are documented (`trivy_reports`, `trivy.report.>`).

## 4. Validation

- [x] 4.1 Unit tests: envelope mapping, subject selection, and deterministic ID generation.
- [x] 4.2 Unit tests: dedupe behavior for repeated informer events.
- [x] 4.3 Integration test: publish path with NATS test server or container.
- [x] 4.4 Manual cluster validation with `kubectl` + `nats` CLI showing live Trivy reports published.

## 5. Documentation

- [x] 5.1 Add `docs/docs/trivy-integration.md` with deployment, config, and troubleshooting steps.
- [x] 5.2 Document operational commands to verify CRDs, sidecar health, and JetStream message flow.
