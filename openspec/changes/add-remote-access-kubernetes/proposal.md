# Change: Add remote access Kubernetes adapters

## Why
ServiceRadar operators need controlled access to private Kubernetes clusters for API inspection, logs, exec, and port-forward workflows without exposing cluster API servers directly or distributing long-lived kubeconfigs to users.

Kubernetes access is high-risk because a naive proxy can become a cluster-admin tunnel, leak service-account tokens, bypass namespace/RBAC boundaries, or hide who ran an exec session. ServiceRadar needs an actor-preserving, route-bound model that fits the existing remote-access foundation.

## What Changes
- Add registered Kubernetes cluster targets routed through selected ServiceRadar agents.
- Support Kubernetes API, logs, exec, and port-forward through explicit namespace/resource/verb policy.
- Prefer Kubernetes impersonation or short-lived client certificates so the target cluster authorizes the real ServiceRadar actor and groups.
- Keep cluster credentials out of browsers and persist only connector credentials required to reach registered clusters.
- Add session lifecycle, approval, audit, recording, byte/stream quotas, and forced termination behavior for Kubernetes sessions.
- Keep current Teleport Kubernetes proxy code as reference only because the current `lib/kube/proxy` dependency graph has AGPL transitive paths.

## Impact
- Affected specs: `edge-architecture`
- Affected code: web-ng Kubernetes access UI/API, core remote-access target/session/policy/audit resources, agent-gateway routing, Go agent Kubernetes adapter, RBAC catalog, demo manifests and fixtures.
