# Change: Stabilize Helm Demo Deployment (secrets, config, NATS, storage)

## Why
- Helm install for the demo namespace leaves critical services crashlooping (NATS mount failure, missing ConfigMap payloads, missing PVC/DB secrets).
- Proton and controller-manager components are unnecessary for the trimmed demo and create extra failures.

## What Changes
- Fix `serviceradar-config` rendering so all keys (including `nats.conf`) ship to the cluster.
- Add/ensure required storage and secrets for core/CNPG consumers (core PVC, cnpg-superuser) and tighten secret generation to auth-only keys.
- Gate optional components (Proton, SPIRE controller manager) and fix NATS config mounting to unblock dependent pods.

## Impact
- Affected code: `helm/serviceradar/templates/*`, `helm/serviceradar/files/serviceradar-config.yaml`
- Affected specs: none (operational/deployment fixes)

## Current State (demo + demo-staging)
- Done: ConfigMap renders all keys (including `nats.conf`), NATS mounts via directory and is Ready, core PVC + `cnpg-superuser` secret provisioned, Proton disabled/removed from demo. SPIRE chart aligned with k8s/demo PSAT settings (token audience `spire-server`, projected SA tokens, controller manager enabled, ClusterSPIFFEIDs present). Agents issue SVIDs; datasvc is healthy with SPIFFE.
- Edge onboarding: secret-generator now seeds `edge-onboarding-key` (overrideable via values) and core consumes it; SPIRE alignment unblocks SVID fetch across services.
- CNPG: Core uses `spire` user/DB with CNPG CA mounted and reaches CNPG. The problematic device metrics CAGG has been rewritten into single-hypertable CAGGs (`device_metrics_summary_cpu|disk|memory`) plus a `device_metrics_summary` view; the SQL now applies successfully on Timescale 2.24. CNPG passwords come from `spire-db-credentials`/`cnpg-superuser` (currently “changeme”).
- Blockers cleared: Agent is stable (hostNetwork + `ClusterFirstWithHostNet`, bumped memory), db-event-writer healthy with CNPG CA/TLS, flowgger rebuilt on Debian testing (OpenSSL 3.2) and probes switched to TCP, and a CNPG init job now provisions the `serviceradar` DB/user/privileges. Demo is running image tag `1.0.56` for flowgger; remove the init container hack entirely.
