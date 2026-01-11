# Change: Fix Services Page and SRQL Integration

## Why

The services page in web-ng is broken due to two distinct bugs:

1. **SRQL NIF serialization error**: The Rust native code cannot serialize `TimeFilterSpec::RelativeHours` containing integers, causing queries with time filters like `time:last_1h` to fail with: `"failed to encode SRQL AST: cannot serialize tagged newtype variant TimeFilterSpec::RelativeHours containing an integer"`

2. **Tenant context not propagated**: The SRQL AshAdapter fails with `Ash.Error.Invalid.TenantRequired` when querying `services` and `gateways` entities because the tenant context from the authenticated user session is not being passed through to Ash.

These bugs prevent the services page from displaying any data, and also affect the analytics dashboard's services stat cards.

## Background

The services page was originally built around pollers that collected health checks. The architecture has evolved:
- **Old model**: Pollers -> Core -> UI
- **New model**: Agents push status -> Agent Gateway -> Core -> UI

The `services` SRQL entity maps to `ServiceRadar.Monitoring.ServiceCheck`, which represents scheduled monitoring checks (ping, HTTP, TCP, SNMP, etc.). The ServiceCheck resource uses:
- Multitenancy with `strategy: :context` - requires tenant to be set in Ash context
- Policies that verify `tenant_id == ^actor(:tenant_id)` - requires an actor with tenant_id

## What Changes

### Bug Fix: TimeFilterSpec Serialization
- Fix the Rust NIF serialization in `native/srql_nif/` to properly encode `TimeFilterSpec::RelativeHours` and similar variants
- Ensure all time filter types serialize correctly to JSON

### Bug Fix: Tenant Context Propagation
- Update SRQL AshAdapter to extract tenant from the current user/scope and pass it to Ash queries
- Ensure the `actor` option is passed to all Ash domain calls with the authenticated user
- Set the `tenant` option for resources that use context-based multitenancy

### Enhancement: Services Page Data Model
- Review whether `ServiceCheck` (scheduled checks) is the right model for the services page
- Consider whether we need a separate `ServiceStatus` model for agent-pushed status updates
- Update SRQL catalog field mappings if the underlying model changes

## Impact

- **Affected specs**: `srql`, `tenant-isolation`
- **Affected code**:
  - `web-ng/native/srql_nif/` - Rust serialization
  - `web-ng/lib/serviceradar_web_ng/srql/ash_adapter.ex` - Tenant propagation
  - `web-ng/lib/serviceradar_web_ng_web/live/service_live/index.ex` - Services page
  - `web-ng/lib/serviceradar_web_ng_web/live/analytics_live/index.ex` - Analytics stats
  - `elixir/serviceradar_core/lib/serviceradar/monitoring/service_check.ex` - ServiceCheck resource
