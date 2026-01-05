# Sync Service Integrations

## Summary

Unify sync service onboarding with a multi-tenant runtime that integrates with the agent/agent-gateway pipeline. The platform sync service authenticates via mTLS, bootstraps with Hello + GetConfig, processes per-tenant integration configs from Ash, and forwards device updates through agent-gateway to core-elx and DIRE. Edge sync deployments remain tenant-locked by mTLS identity. The sync service no longer uses datasvc/KV. All device updates reuse existing AgentGatewayService push RPCs with ResultsChunk-compatible chunking (no new sync-specific RPCs). Sync ships with a minimal bootstrap config generated at onboarding; full config arrives over gRPC.

## Motivation

Currently:
1. Sync is not integrated with the agent/agent-gateway pipeline for device updates.
2. Sync configuration relies on KV, which is unavailable or inappropriate for edge and multi-tenant workflows.
3. Sync is not multi-tenant aware; discovered devices are not consistently tenant-scoped.
4. Platform vs tenant service identities are not clearly distinguished by mTLS, making authorization ambiguous.
5. Platform bootstrap uses a fixed tenant ID, limiting clean platform identity mapping.

The proposed changes:
1. Sync services bootstrap via Hello + GetConfig using mTLS through agent-gateway.
2. Platform sync processes per-tenant integration configs; edge sync is tenant-restricted.
3. Device updates flow through agent -> agent-gateway -> core-elx -> DIRE for canonical records.
4. Sync no longer depends on datasvc/KV for configuration or state.
5. Sync results reuse existing AgentGatewayService StreamStatus push RPCs with ResultsChunk-compatible chunking (no new RPCs).
6. Platform bootstrap creates a random platform tenant UUID and platform service mTLS identities.
7. Onboarding generates a minimal sync config; the UI includes an "Add Edge Sync Service" action near "New Source".

## Scope

### In Scope
- SyncService Ash resource for onboarding and health tracking
- Per-tenant integration config delivery via GetConfig
- Go sync service updates for Hello + GetConfig and per-tenant loops
- Agent/agent-gateway ingestion of sync device updates
- DIRE processing of sync updates into canonical device records
- mTLS identity classification for platform vs tenant sync services
- Platform bootstrap enhancements (random platform tenant UUID + platform certs)
- UI gating and sync service assignment for integrations

### Out of Scope
- New integration adapters (Armis/NetBox/Faker behavior changes)
- NATS integration (covered by separate proposal)
- Agent local config file format changes beyond GetConfig payloads

## Dependencies

- `update-agent-saas-connectivity` (Hello/GetConfig protocol)
- `add-platform-bootstrap` (bootstrap flow)
- Existing IntegrationSource Ash resource

## Related Specs

- `specs/tenant-isolation/spec.md`
- `specs/device-identity-reconciliation/spec.md`
- `specs/kv-configuration/spec.md`
- `specs/edge-architecture/spec.md`

## Status

**Approved** - Ready for implementation
