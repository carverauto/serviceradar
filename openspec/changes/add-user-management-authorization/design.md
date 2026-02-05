## Context
ServiceRadar installs with a single bootstrapped admin user. After install, admins cannot add additional users, manage roles, or control how SSO group/claim data maps to authorization roles. This proposal introduces user management and authorization settings under Settings -> Auth while keeping authentication provider configuration in the separate SSO change.

## Goals / Non-Goals
- Goals:
  - Provide an admin-managed user directory with lifecycle actions.
  - Allow admins to manage role assignments and SSO claim/group role mapping.
  - Centralize access management under Settings -> Auth.
  - Ensure all actions are audited and RBAC enforced.
- Non-Goals:
  - Implement authentication provider configuration (handled by `add-enterprise-sso-authentication`).
  - Introduce multi-tenant features or cross-instance user federation.
  - Replace Ash policy enforcement with a new authorization engine (Permit integration remains future work).

## Decisions
- Use Ash resources/actions in the Identity domain for all user lifecycle changes (create, update, deactivate, role change).
- Store role mapping configuration in platform schema and apply it on login (SSO and local).
- Soft-deactivate users rather than hard delete; deactivation revokes active sessions and API tokens.
- Surface role mapping and user management in a single Settings -> Auth section with clear admin-only UI.

## Risks / Trade-offs
- Risk: Misconfigured role mapping could grant overly broad access.
  - Mitigation: Default to least-privileged role and require explicit mapping; add audit logs for changes.
- Risk: Deactivation may orphan resources or jobs tied to a user.
  - Mitigation: Keep user records, use status flag, and avoid hard delete.

## Migration Plan
- Add database migrations (Elixir) for any new user status fields and role mapping configuration storage in the platform schema.
- Backfill existing users with default role and active status if missing.
- Deploy UI + API; no breaking changes to existing sessions besides role evaluation on next request.

## Open Questions
- Should admin-created users receive a temporary password or a magic-link invite by default?
- Do we allow admin-driven password resets for local users, or only send invite/reset emails?
- Should role mapping support multiple roles per user, or enforce a single primary role?
