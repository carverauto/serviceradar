# Proposal: Restrict Platform Actor Scope

## Problem Statement

The current `SystemActor.platform/1` function creates platform-scoped actors that enable cross-tenant operations inside tenant instances. This violates the single-tenant deployment model and increases security risk.

Key risks:

1. **Overly broad permissions**: Platform actors imply god-mode access across deployments
2. **Abuse potential**: Any code using platform actors could access data outside the instance
3. **Unclear boundaries**: Platform operations are mixed into tenant instance code
4. **Tenant deletion risk**: Platform actors could bypass proper closure workflows

## Current State

Platform actors are used for:
- Listing tenants (seeders, bootstrap)
- Looking up tenants by slug (authentication flows)
- Creating NATS operators (infrastructure bootstrap)
- Querying cross-tenant resources during startup

## Proposed Solution

1. **Remove `SystemActor.platform/1` from tenant instances**
   - Tenant instances only use `SystemActor.system/1`
   - No platform-scoped actors in instance code

2. **Move platform operations to the Control Plane**
   - Bootstrap, tenant management, and NATS provisioning live in the control plane
   - Tenant instances operate only on their own data

3. **Eliminate cross-tenant queries in tenant instances**
   - No tenant iteration or cross-tenant lookups
   - Instance isolation enforced by DB search_path

## Security Boundaries

| Operation | Allowed Component | Notes |
|-----------|-------------------|-------|
| List all tenants (metadata only) | Control Plane | Not in tenant instance |
| Create NATS operator | Control Plane | Not in tenant instance |
| Read tenant data | Tenant instance | Single-tenant only |
| Modify tenant data | Tenant instance | Admin/operator only |
| Cross-tenant access | Control Plane | Never in tenant instance |

## Migration Path

1. Remove `SystemActor.platform/1` and all usages in tenant instance code
2. Move platform bootstrap and provisioning to the control plane
3. Verify no cross-tenant queries remain in the instance

## Success Criteria

- No platform actor exists in tenant instance code
- No cross-tenant operations in tenant instances
- Platform operations handled by control plane only
- Policy tests verify instance isolation
