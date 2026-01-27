## Context
Issue 2485 highlights static database passwords (notably `postgres` = `changeme`) and default public exposure for CNPG in Docker Compose. We need a secure-by-default approach that still supports local development and k8s deployments without breaking existing clusters.

## Goals / Non-Goals
- Goals:
  - Eliminate static default DB passwords across Docker Compose and Helm.
  - Persist generated credentials so restarts do not rotate credentials unexpectedly.
  - Make CNPG network exposure opt-in in Docker Compose.
- Non-Goals:
  - Full secrets-manager integration.
  - Automated password rotation for existing clusters.

## Decisions
- Decision: Helm templates generate random passwords for `cnpg-superuser` and `spire-db-credentials` when not supplied, and preserve existing secrets.
  - Why: Helm already uses `lookup` + `resource-policy: keep`, so we can extend the same behavior to avoid rotations.
- Decision: Docker Compose uses a dedicated volume to store credential files and a bootstrap container to create them on first run.
  - Why: Compose does not have native secret persistence, and we need credentials available to multiple containers without committing them.
- Decision: CNPG default port binding is loopback (`127.0.0.1`) for Docker Compose.
  - Why: Prevents accidental public exposure; users can opt in by setting `CNPG_PUBLIC_BIND`.

## Risks / Trade-offs
- Existing deployments expecting `changeme` or `serviceradar` defaults must update configs if they rely on the defaults.
- File-based credential loading may require small entrypoint updates for services that only read env vars today.

## Migration Plan
1. For Helm installs, existing secrets are reused; new installs get random passwords.
2. For Docker Compose, new bootstrap writes passwords to the volume. Existing installs must seed credentials explicitly (via env or pre-created files) before starting; no legacy defaults are assumed.
3. Document recovery/rotation steps (delete secret/volume to regenerate, plus explicit service restarts).

## Open Questions
- Do any services outside Helm/Compose rely on the `postgres` superuser password at runtime? If so, we must add file-based loading there too.
