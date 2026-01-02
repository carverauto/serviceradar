# Change: Update agent SaaS connectivity and configuration

## Why
Pollers currently reach into customer networks over gRPC, which requires inbound firewall rules and is unacceptable for SaaS deployments. Agents must initiate outbound connections and receive their configuration from the SaaS control plane.

## What Changes
- **BREAKING** Agents initiate outbound mTLS gRPC to the SaaS control plane for hello/enrollment and configuration retrieval.
- Introduce or repurpose an agent-facing ingress service (poller or new gateway) to receive agent traffic and emit Ash pubsub events for enrollment and status updates.
- Store tenant CA issuer SPKI hashes and resolve tenant identity from the server-validated issuer certificate during agent connection validation.
- Core-elx generates agent configuration from tenant data in CNPG via Ash resources and provides versioned config responses.
- Agents poll for configuration updates every 5 minutes and apply role/check assignments from the server.
- Local agent configuration is reduced to the SaaS endpoint and mTLS credentials; no per-check configuration is stored on disk.
- Agent binary updates for the new hello/config polling flow are deferred to a follow-up change.

## Impact
- Affected specs: agent-connectivity (new)
- Affected code: elixir/serviceradar_poller (agent-gateway ingress), elixir/serviceradar_core (Ash resources/services, proto stubs), proto/*, web-ng (agent status/config UI), docs/docs/architecture.md
