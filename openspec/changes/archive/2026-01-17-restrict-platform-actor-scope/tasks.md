## 1. Remove Platform Actor Usage

- [ ] 1.1 Remove `SystemActor.platform/1` from tenant instance code.
- [ ] 1.2 Update all call sites to use `SystemActor.system/1` (or instance user actors).
- [ ] 1.3 Delete any remaining platform-scoped actor helpers.

## 2. Remove Cross-Tenant Operations

- [ ] 2.1 Remove tenant iteration utilities from tenant instance code.
- [ ] 2.2 Ensure no cross-tenant queries remain in instance services.
- [ ] 2.3 Verify DB search_path is the only isolation mechanism in tenant instance.

## 3. Update Authorization Policies

- [ ] 3.1 Remove any policy bypasses tied to platform roles.
- [ ] 3.2 Ensure system actor bypass is the only non-user bypass.

## 4. Documentation

- [ ] 4.1 Document instance-only actor usage in CLAUDE.md.
- [ ] 4.2 Document control-plane-only responsibilities.

## 5. Verification

- [ ] 5.1 Run targeted tests for affected services.
- [ ] 5.2 Verify no platform actor remains via code search.
