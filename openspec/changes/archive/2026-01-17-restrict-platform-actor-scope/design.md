# Design: Restricted Platform Actor Scope

## Architectural Context

ServiceRadar runs as single-tenant deployments. Platform operations (tenant provisioning, NATS/CNPG setup) are handled by the Control Plane outside the tenant instance. Tenant instances should not contain platform-scoped actors or cross-tenant logic.

## Decision

- Remove `SystemActor.platform/1` from tenant instance code.
- Use `SystemActor.system/1` for background jobs inside the instance.
- Move any platform operations to the Control Plane.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Platform operations no longer available in tenant instance | Ensure Control Plane owns bootstrap/provisioning |
| Legacy code paths rely on platform actor | Audit and remove cross-tenant queries |

## Migration Plan

1. Delete `SystemActor.platform/1` and replace call sites.
2. Remove platform resources from tenant instance code.
3. Validate that no cross-tenant queries remain.
