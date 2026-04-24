# Change: Add RBAC Policy Editor and Custom Role Profiles

## Why
- Viewer users can still access destructive UI controls, which indicates that permissions are not consistently enforced.
- Admins need configurable RBAC beyond the fixed roles to match real-world operational boundaries.

## What Changes
- Add an RBAC permission catalog (sections/capabilities/actions) and a role profile model for built-in (admin/operator/viewer) and custom profiles.
- Add an admin RBAC policy editor UI (matrix view) to manage role profiles and permissions.
- Enforce RBAC consistently across UI visibility/behavior and API authorization.
- Add admin API endpoints for managing role profiles and permissions.
- Update authorization logic to evaluate effective permissions via role profiles.
- **Potentially breaking**: authorization checks may shift from role-only to profile-based evaluation; defaults must match current behavior.

## Impact
- Affected specs: `ash-authorization` (modified), new `rbac-policy-management` (added).
- Affected systems: web-ng UI, web-ng admin API, core authorization policies, database schema (role profile storage).
- Related changes: `add-user-management-authorization` (must remain compatible with new profile assignments).
