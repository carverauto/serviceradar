# Change: Add User Management and Authorization Settings

## Why
ServiceRadar bootstraps a single admin user at install time, but there is no supported way to add, manage, or deactivate users, nor to configure authorization rules beyond that first admin. This blocks real deployments where multiple operators need access and admins must control roles and SSO role mapping. GitHub issue #2541 captures this gap.

## What Changes
- Add a first-class user management capability (list, create/invite, edit, deactivate/reactivate, reset access) for admins.
- Add authorization settings for default role and IdP group/claim-to-role mapping, with audit logging.
- Add Settings -> Auth navigation with "Users" and "Authorization" tabs (authentication provider settings are handled by `add-enterprise-sso-authentication`).
- Enforce RBAC so only admin/super_user can manage users or authorization settings, using Permit as the authorization engine.

## Impact
- Affected specs:
  - `build-web-ui` (Settings -> Auth UI)
  - `ash-authorization` (admin-only controls, role mapping behavior)
  - `user-management` (new capability)
- Affected code (expected):
  - `elixir/serviceradar_core` Identity domain (User actions, role mapping, audit events)
  - `web-ng` settings pages and admin APIs
  - Permit authorization modules and Phoenix integration (controllers + LiveView)

## Dependencies
- `add-enterprise-sso-authentication` should land first for authentication provider configuration and login flow.
