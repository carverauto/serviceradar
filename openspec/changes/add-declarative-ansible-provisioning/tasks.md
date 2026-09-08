## 1. Contract and Existing API

- [x] 1.1 Inventory existing API, authentication, Ansible services, and active specifications.
- [x] 1.2 Review and approve this proposal before implementing new capabilities.
- [ ] 1.3 Define OpenAPI resources, pagination, errors, concurrency, idempotency, and readiness.
- [x] 1.4 Enforce account RBAC intersected with token capabilities on configuration routes.
- [x] 1.5 Complete credential/controller lifecycle with canonical guarded-deletion services.
- [x] 1.6 Expose repository lifecycle and explicit sync/status through existing services.
- [ ] 1.7 Expose inventory/membership discovery and evidence-backed review.
- [ ] 1.8 Expose immutable binding prepare/review/revoke and canonical operation APIs.
- [ ] 1.9 Test real bearer/API-key authentication, read-only tokens, revoked users, and resource scope.

## 2. Upstream AWX Provisioning

- [ ] 2.1 Add typed managed-resource ownership and durable provisioning operation contracts.
- [ ] 2.2 Add distinct provisioning permission, credential purpose, and complete usage tracking.
- [ ] 2.3 Add bounded agent commands for project/inventory/source/environment/template/role reconciliation.
- [ ] 2.4 Implement exact request-body custody and secret-free results; reject arbitrary proxy input.
- [ ] 2.5 Implement explicit import/adoption, partial recovery, ambiguous-create reconciliation, and deletion guards.
- [ ] 2.6 Verify real Wasm host lifecycle and synthetic AWX compatibility, including denied mutations.

## 3. Terraform Client

- [x] 3.1 Add a first-party provider with Bazel build/test targets and pinned dependencies.
- [ ] 3.2 Add resource/data-source lifecycle, import, canonical refresh, and bounded operation polling.
- [x] 3.3 Add write-only credential inputs and rotation version without secret persistence.
- [ ] 3.4 Add a synthetic complete bootstrap example and explicit review/deployment follow-up.
- [ ] 3.5 Prove no-op second apply, drift, adoption, guarded destroy, and secret-free plan/state.

## 4. Verification and Documentation

- [ ] 4.1 Document permissions, initial trust, supported AWX versions, ownership, and recovery.
- [ ] 4.2 Verify clean bootstrap and existing-install import using only the public ServiceRadar API.
- [ ] 4.3 Verify a separate authorized canary deployment through canonical prepare/launch/status.
- [ ] 4.4 Run focused integration checks and the required complete Bazel unit suite before PR.

## Initial Delivery Status

The first provider delivery manages ServiceRadar credentials, credential rules,
controllers, and playbook repositories. Real Terraform CLI acceptance covers
their import, no-op apply, drift repair, rotation, guarded deletion, and secret
absence from plan/state artifacts. Upstream AWX object provisioning and adoption
remain pending, so the complete bootstrap tasks above are not yet checked.

Membership review and non-callback binding prepare/create/revoke APIs are
implemented. Canonical operation prepare/launch/status are exposed; cancellation
returns an explicit unsupported response until durable child cleanup exists.
Database-backed authentication and lifecycle tests are registered in the guarded
CI lanes. Their execution and a fresh canonical deployment canary remain part of
the verification work. The complete repository unit suite passed before the
initial draft PR.
