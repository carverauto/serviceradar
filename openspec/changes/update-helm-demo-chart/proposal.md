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
