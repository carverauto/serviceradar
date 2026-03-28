## Context
Agents already support verified staging, activation, and rollback, but artifact transport still assumes direct external HTTPS reachability. The control plane now has a repository-release importer and a manual publish path, but neither currently mirrors release artifacts into internal storage. The repo already contains JetStream object-store support through `datasvc`, and gateways are the expected reachability point for many edge nodes.

## Goals
- Keep GitHub/Forgejo/Harbor releases as the operator-facing source of truth.
- Mirror rollout artifacts and signed manifest payloads into ServiceRadar-managed storage at publish/import time.
- Serve release artifacts to agents through `agent-gateway`.
- Preserve the existing trust model: the agent still verifies the signed manifest and artifact digest locally.
- Preserve a simple manual publish path for developer and local testing workflows.

## Non-Goals
- Streaming artifacts over the control command bus.
- Making JetStream object storage itself the trust anchor for release integrity.
- Replacing package-managed bootstrap installs with self-update for first install.

## Architecture
1. Operator imports a repo-hosted release or manually publishes a release.
2. The control plane validates the signed manifest and stores the release catalog entry.
3. The control plane mirrors each referenced rollout artifact into JetStream object storage and records internal storage metadata in the release manifest/catalog metadata.
4. When a rollout target dispatches, the command payload references the internal artifact identity or gateway-served download URL instead of an external repo URL.
5. `agent-gateway` exposes an authenticated HTTPS artifact-download endpoint for connected/authorized agents and fetches the object payload from JetStream object storage on demand.
6. The agent downloads the artifact from `agent-gateway`, then verifies the signed manifest and SHA256 digest before staging.

## Key Decisions

### JetStream object store is the internal distribution backend
This fits the existing ServiceRadar data plane, avoids introducing another artifact store immediately, and works for disconnected gateway-local fetch patterns better than requiring direct repo access from agents.

### Gateway serves artifacts over HTTPS rather than proxying them over the command stream
Artifacts can be large, and the command bus should remain control-plane oriented. HTTPS download from gateway is operationally simpler and aligns with the existing agent verifier.

### Manual publishing remains supported
Developers need a local path that does not require pushing production-style releases to GitHub/Forgejo/Harbor. Manual publish should continue to exist, but publish-time ingestion should still stage artifacts into internal storage so rollout delivery remains realistic.

### Internal storage is not a trust anchor
The agent must continue to verify the Ed25519-signed manifest and SHA256 digest. This keeps transport and trust separated and limits damage from a compromised gateway or storage layer.

## Risks
- Artifact mirroring introduces storage lifecycle and cleanup requirements.
- Gateway delivery adds authorization and availability requirements to `agent-gateway`.
- Large rollout artifacts may increase JetStream storage pressure.

## Mitigations
- Add release-asset retention and deletion semantics later if needed, but record enough metadata now for cleanup tooling.
- Restrict gateway artifact serving to authorized agents and scoped release targets.
- Enforce artifact size limits and reuse existing release validation.
