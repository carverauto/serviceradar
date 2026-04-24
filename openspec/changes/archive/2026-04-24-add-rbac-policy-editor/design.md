## Context
We need RBAC that is enforced uniformly across UI and API while supporting both fixed roles and custom profiles. The current role-based model is too coarse and does not consistently hide or deny restricted actions (e.g., device delete for viewer users).

## Goals / Non-Goals
- Goals:
  - Provide a permission catalog that is used by UI and API enforcement.
  - Preserve built-in roles (admin, operator, viewer) with defaults that match current behavior.
  - Support custom role profiles that admins can create, edit, and assign.
  - Ensure UI visibility and API authorization use the same RBAC evaluation.
- Non-Goals:
  - Replace Ash or Permit policy systems with a new authorization framework.
  - Introduce per-tenant or multi-deployment routing (single-deployment only).

## Decisions
- Role profiles:
  - Create a role profile resource with a stable `system_name` for built-in profiles and `custom_name` for admin-defined profiles.
  - Built-in roles map to system profiles; they are not deletable and are only clonable (not editable).
- User assignment:
  - Users have an optional `role_profile_id` with fallback to their legacy `role` field for compatibility.
- Permission catalog:
  - Define a canonical list of permission keys grouped by section (analytics, devices, services, observability, settings) and actions (view, create, update, delete, execute, manage, etc.).
  - Permission catalog is action-level for robust v1 granularity.
  - RBAC evaluation resolves allowed actions by profile and is shared by UI gating and API enforcement.
- Enforcement:
  - UI uses the RBAC evaluator to hide or disable controls and routes.
  - API checks permissions via Permit/Ash policy integration with the same evaluator.

## Risks / Trade-offs
- Role/profile migration: incorrect defaults could grant or deny access unexpectedly.
- UI and API must remain in sync; adding a permission key requires catalog updates and tests.

## Migration Plan
1. Add role profile tables/resources and seed built-in profiles.
2. Backfill existing users to default profiles derived from their current role.
3. Switch authorization checks to profile-based evaluation with a fallback to legacy roles.
4. Enable UI gating based on profile permissions.

## Open Questions
- None for this change (decisions recorded above).
