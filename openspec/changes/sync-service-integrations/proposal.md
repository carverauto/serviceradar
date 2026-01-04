# Sync Service Integrations

## Summary

Add sync service onboarding and integration source management. Sync services must be onboarded before integration sources (Armis/NetBox/Faker) appear in the UI. The SaaS sync service auto-onboards at platform bootstrap. Customers can add on-prem sync services. Users select which sync service processes each integration. Data flows from integration sources through sync service to CNPG, then to agent config via GetConfig.

## Motivation

Currently:
1. Integration sources are always visible in the UI regardless of sync service availability
2. There's no concept of "sync service onboarding" - sync services just exist
3. Agents depend on KV store for sweep config (sweep.json), but edge-deployed agents have no KV access
4. No way for customers to choose between SaaS and on-prem sync services
5. Integration config syncs to datasvc KV, but this doesn't work for edge agents

The proposed changes:
1. Gate integration source UI on sync service availability
2. Auto-onboard SaaS sync at platform bootstrap
3. Allow customers to onboard on-prem sync services
4. Let users assign integrations to specific sync services
5. Route discovered device data through CNPG instead of KV
6. Include sweep config in GetConfig response (eliminates KV dependency for agents)

## Scope

### In Scope
- SyncService Ash resource for tracking onboarded sync services
- Platform bootstrap logic to auto-onboard SaaS sync
- On-prem sync service onboarding flow
- UI gating for integration sources based on sync availability
- Sync service selector when creating/editing integrations
- Device data storage in CNPG (replacing KV flow)
- Sweep config generation from CNPG device data
- GetConfig enhancement to include sweep targets

### Out of Scope
- Changes to the Go sync service binary itself (only config/onboarding)
- NATS integration (covered by separate proposal)
- Agent local config file format changes

## Dependencies

- `update-agent-saas-connectivity` - Provides Hello/GetConfig gRPC protocol
- Existing IntegrationSource Ash resource
- Existing sync service Go implementation

## Related Specs

- `specs/agent-gateway-protocol/` - Agent enrollment and config delivery
- `specs/multi-tenancy/` - Tenant isolation for sync services

## Status

**Draft** - Awaiting review
