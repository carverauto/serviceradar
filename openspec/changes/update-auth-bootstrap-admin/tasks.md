## 1. Discovery & Design
- [x] 1.1 Confirm the AshAuthentication user store (table/resource) used for web-ng login and existing password hashing helpers.
- [x] 1.2 Decide the bootstrap execution point (web-ng startup vs. dedicated init job) and idempotency rules.
- [x] 1.3 Define where credentials are stored and surfaced for Compose, Helm, and K8s manifests.

## 2. Implementation
- [x] 2.1 Implement admin bootstrap logic (random password generation + bcrypt) and ensure it is idempotent.
- [x] 2.2 Remove magic-link login endpoints and magic-link flows from the web UI.
- [x] 2.3 Disable registration endpoints and remove register links from sign-in pages.
- [x] 2.4 Docker Compose: add bootstrap hook/job to create admin user and persist credentials to a volume.
- [ ] 2.5 Helm: add bootstrap job/secret and emit credentials via `NOTES.txt`.
- [x] 2.6 K8s manifests: wire admin credential env from secret (bootstrap job/notes pending).
- [x] 2.7 Add tests for bootstrap idempotency and disabled auth flows.
- [x] 2.8 Make pg_stat_statements and Oban schema setup idempotent in core migrations.

## 3. Docs & Validation
- [x] 3.1 Update operator docs with the new login and credential retrieval steps.
- [ ] 3.2 Validate with Docker Compose and Helm template render (or kustomize build).
