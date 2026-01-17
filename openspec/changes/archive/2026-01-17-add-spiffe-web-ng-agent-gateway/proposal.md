# Change: Add SPIFFE support for web-ng and deploy agent-gateway via Helm

## Why
The demo-staging Helm install relies on SPIFFE for in-cluster identity, but web-ng still assumes file-based mTLS for datasvc and the agent-gateway workload is missing. This blocks clean, idempotent Helm installs and forces manual intervention when SPIFFE is required.

## What Changes
- Add SPIFFE-aware gRPC configuration in web-ng so datasvc connections can use SPIFFE SVIDs in Kubernetes while retaining file-based mTLS for Docker Compose.
- Implement SPIFFE Workload API support in Elixir so web-ng/core-elx can fetch X.509 SVIDs via the SPIRE agent socket.
- Add Helm values and templates to deploy serviceradar-agent-gateway with tenant-CA mTLS for edge gRPC and ERTS cluster wiring (no SPIFFE on gateway).
- Ensure Helm installs set the correct datasvc connection parameters for web-ng (service hostname + TLS mode selection) so NATS bootstrap succeeds.

## Impact
- Affected specs: edge-architecture.
- Affected code: web-ng runtime config, Helm chart templates/values, agent-gateway deployment manifests.
