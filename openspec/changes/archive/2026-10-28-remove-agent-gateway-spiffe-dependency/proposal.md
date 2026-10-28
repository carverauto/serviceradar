# Change: Remove hard SPIFFE dependency from hosted agent-gateway identity

## Why
The hosted edge-agent path is supposed to run on plain mTLS without requiring SPIFFE or SPIRE. The current spec and code drifted apart: demo and Helm documentation now describe SPIFFE as optional for default deployments, but the agent-gateway identity path still depends on a SPIFFE URI SAN to derive `component_type`, and the edge-architecture spec still encodes tenant workload identity through SPIFFE. That keeps deprecated identity assumptions in the one path we explicitly want to work without SPIFFE.

## What Changes
- Update the edge-agent identity model so hosted agent-gateway authentication works with plain mTLS certificates and a tenant-scoped CA without requiring SPIFFE or SPIRE.
- Treat SPIFFE URI SAN parsing as a backward-compatible input only for the hosted edge-agent path rather than a normative requirement.
- Define the hosted agent certificate identity fields around tenant or partition trust, `component_id`, and partition identity from the certificate CN and tenant CA chain.
- Define hosted agent-gateway behavior when SPIFFE SANs are absent: it still authenticates the client and authorizes the connection as an `agent`.
- Align gateway-issued certificate bundles and onboarding expectations with the non-SPIFFE mTLS model.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/component_identity_resolver.ex`, `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_gateway_server.ex`, `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/cert_issuer.ex`, related onboarding and documentation paths
