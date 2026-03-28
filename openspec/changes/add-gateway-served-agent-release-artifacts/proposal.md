# Change: Add gateway-served agent release artifacts backed by JetStream object storage

## Why
The current agent release-management path assumes edge agents can download rollout artifacts directly from an external HTTPS URL. That does not match the real network model for many deployments, where agents typically only have reachability to their local `agent-gateway`.

We need a release-delivery path that keeps Forgejo/Harbor/GitHub as the source of truth for published releases while distributing rollout artifacts through ServiceRadar-managed infrastructure. The control plane should ingest signed release artifacts into internal storage, and gateways should serve those artifacts to agents over the existing trusted edge path.

## What Changes
- Extend agent release management so imported or manually published releases can stage artifact payloads into JetStream object storage instead of relying on direct external artifact URLs at rollout time.
- Add gateway-served artifact delivery so agents download rollout payloads from `agent-gateway` over HTTPS instead of requiring direct access to Forgejo/Harbor/GitHub.
- Preserve the existing manual publish workflow for developer and local validation scenarios, but store the resulting artifact payloads in internal object storage when the release is published.
- Keep repository-hosted releases as the operator-facing source of truth by importing signed manifest assets from GitHub first, with the same model designed to support Forgejo and Harbor-backed release sources.
- Preserve agent-side Ed25519 manifest verification and SHA256 artifact validation so gateways and object storage remain transport layers rather than trust anchors.

## Impact
- Affected specs: `agent-release-management`, `agent-connectivity`, `edge-architecture`
- Affected code:
  - `elixir/serviceradar_core`
  - `elixir/serviceradar_agent_gateway`
  - `elixir/web-ng`
  - `go/cmd/agent`
  - `go/pkg/agent`
  - `go/pkg/datasvc`
  - release publishing/import workflow docs
