## Context
The current login flow relied on magic-link emails backed by a local mail adapter, which is not viable for production and is being removed. We need a secure admin bootstrap flow that works for Docker Compose, Helm, and demo manifests.

## Goals / Non-Goals
- Goals:
  - Provide a deterministic, secure admin login path for self-hosted installs.
  - Remove magic-link and self-registration flows in default deployments.
  - Persist generated credentials in installation-specific storage and surface them once to operators.
  - Keep the bootstrap logic idempotent and safe to re-run.
- Non-Goals:
  - Implement the long-term authentication roadmap (SSO/OAuth, invite flows, etc.).
  - Add multi-tenant authentication overrides or bypass modes.

## Decisions
- Decision: Bootstrap a default admin user (`admin` / `root@localhost`) during installation.
  - Rationale: Provides a predictable login path without requiring SMTP or external IdP setup.
- Decision: Generate a random password once, hash it with bcrypt, store the hash in the auth user store, and persist the plaintext to install-specific secret/volume storage.
  - Rationale: Avoids logging secrets in plaintext while still giving operators a retrievable credential.
- Decision: Remove magic-link and registration routes and UI entry points.
  - Rationale: Eliminates unsupported flows that depend on the local mail adapter.
- Decision: Use an idempotent bootstrap job/hook so retries do not overwrite existing admin credentials.
  - Rationale: Safe restarts and re-deploys without credential churn.

## Risks / Trade-offs
- Exposing credentials: ensure plaintext only appears in controlled outputs (Helm notes, job logs) and is stored in secrets/volumes with restricted permissions.
- Operational confusion: clearly document where credentials are stored and how to rotate them.
- Partial migrations: existing deployments may have users created via magic links; avoid deleting or overwriting existing accounts.

## Migration Plan
- On startup, check for existing admin user by email and role.
- If present, skip bootstrap and emit a message indicating existing credentials are retained.
- If absent, create the admin user, persist the password, and emit the one-time login message.

## Open Questions
- Resolved: use `ServiceRadar.Identity.User` (AshAuthentication user store).
- Resolved: Compose stores the plaintext password in `/etc/serviceradar/admin/admin-password` (admin creds volume).
- Open: Decide how Helm and demo manifest installs surface the password (Helm notes vs. job logs vs. secret reference).
