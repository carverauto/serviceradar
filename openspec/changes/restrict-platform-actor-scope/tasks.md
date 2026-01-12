## 1. Define Scoped Platform Roles

- [ ] 1.1 Define `:platform_reader` role (read-only tenant metadata access).
- [ ] 1.2 Define `:platform_bootstrap` role (one-time infrastructure setup).
- [ ] 1.3 Define `:platform_seeder` role (seed default data into tenants).
- [ ] 1.4 Document role boundaries in SystemActor module.

## 2. Update SystemActor Module

- [ ] 2.1 Add `platform/2` function with explicit scope parameter.
- [ ] 2.2 Deprecate or remove `:super_admin` role usage.
- [ ] 2.3 Update all callers to specify appropriate scope.
- [ ] 2.4 Add compile-time or runtime validation of scope.

## 3. Restrict Tenant Resource Access

- [ ] 3.1 Add policies to Tenant resource for platform roles.
- [ ] 3.2 Ensure platform roles cannot delete/suspend tenants.
- [ ] 3.3 Ensure platform roles can only read metadata (id, slug, status).
- [ ] 3.4 Block platform roles from reading tenant secrets/credentials.

## 4. Audit Current Platform Actor Usages

- [ ] 4.1 List all files using `SystemActor.platform/1`.
- [ ] 4.2 Categorize each usage (bootstrap, seeding, routing, etc.).
- [ ] 4.3 Determine minimum required scope for each usage.
- [ ] 4.4 Document any usages that need redesign.

## 5. Implement Tenant Closure Workflow

- [ ] 5.1 Design self-service tenant closure flow.
- [ ] 5.2 Add billing-triggered suspension/closure hooks.
- [ ] 5.3 Implement grace period before data deletion.
- [ ] 5.4 Add audit logging for all closure actions.
- [ ] 5.5 Remove any direct deletion capabilities from platform actors.

## 6. Update Authorization Policies

- [ ] 6.1 Add `:platform_reader` to Tenant resource read policies.
- [ ] 6.2 Add `:platform_bootstrap` to NatsOperator create policies.
- [ ] 6.3 Add `:platform_seeder` to rule/template create policies.
- [ ] 6.4 Verify no tenant-internal resources allow platform roles.

## 7. Add Policy Tests

- [ ] 7.1 Test that platform_reader cannot read tenant data.
- [ ] 7.2 Test that platform_reader cannot modify tenants.
- [ ] 7.3 Test that no platform role can delete tenants.
- [ ] 7.4 Test that seeders can only create default data.
- [ ] 7.5 Test that bootstrap can only run during initial setup.

## 8. Documentation

- [ ] 8.1 Document platform role boundaries in CLAUDE.md.
- [ ] 8.2 Add security guidelines for cross-tenant operations.
- [ ] 8.3 Document tenant closure workflow.

## 9. Verification

- [ ] 9.1 Run full test suite.
- [ ] 9.2 Manual testing of bootstrap flow.
- [ ] 9.3 Manual testing of seeder flow.
- [ ] 9.4 Verify no unauthorized cross-tenant access is possible.
