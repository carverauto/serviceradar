# Sync Service Integrations

## Summary

Embed the sync runtime inside `serviceradar-agent` so every tenant runs discovery from their own agent deployment. The agent boots with minimal onboarding config, completes Hello + GetConfig, receives integration sources for its tenant, and streams device updates through agent-gateway to core-elx and DIRE. There is no platform-level sync service; sync exists only as an agent capability. The agent still uses existing AgentGatewayService push RPCs with ResultsChunk-compatible chunking (no new sync-specific RPCs). The sync runtime does not use datasvc/KV, and sync pull APIs remain deprecated.

## Motivation

Currently:
1. Standalone sync deployments add operational overhead and duplicate onboarding steps for customers.
2. Sync configuration relies on KV, which is unavailable or inappropriate for edge workflows.
3. Tenant scoping must be enforced at the agent boundary using mTLS identity, not platform multi-tenant sync.
4. Platform vs tenant service identities must remain explicit, but sync should never run as a platform service.

The proposed changes:
1. Agents bootstrap via Hello + GetConfig using mTLS through agent-gateway and include embedded sync capability.
2. Tenant agents process integration configs scoped to their tenant only; no platform sync service exists.
3. Device updates flow through agent -> agent-gateway -> core-elx -> DIRE for canonical records.
4. Embedded sync no longer depends on datasvc/KV for configuration or state.
5. Sync results reuse existing AgentGatewayService StreamStatus push RPCs with ResultsChunk-compatible chunking; pull results APIs remain deprecated.
6. Tenants must onboard at least one agent to use integrations; UI and onboarding flows point to agent onboarding.

## Scope

### In Scope
- Embed sync runtime inside the agent binary (platform and edge use the same agent build)
- Tenant-scoped integration config delivery via Agent GetConfig
- Agent/agent-gateway ingestion of sync device updates
- DIRE processing of sync updates into canonical device records (source of truth)
- mTLS identity classification to enforce tenant scoping for agent-embedded sync
- UI gating and agent assignment for integrations
- Deprecation of sync pull results APIs (StreamResults/GetResults)

### Out of Scope
- New integration adapters (Armis/NetBox/Faker behavior changes)
- NATS integration (covered by separate proposal)
- Agent local config file format changes beyond GetConfig payloads
- DiscoveredDevice staging and SweepConfig generation (superseded by DIRE as source of truth)
- Standalone sync service deployments (removed by this change)

## Dependencies

- `update-agent-saas-connectivity` (Hello/GetConfig protocol)
- Existing IntegrationSource Ash resource

## Related Specs

- `specs/tenant-isolation/spec.md`
- `specs/device-identity-reconciliation/spec.md`
- `specs/kv-configuration/spec.md`
- `specs/edge-architecture/spec.md`

## Status

**Approved** - Ready for implementation
