## 1. Implementation
- [x] 1.1 Remove static default cluster/session/plugin signing secrets from the main Docker Compose stack and replace them with generated or file-backed values.
- [x] 1.2 Restrict NATS monitoring exposure so the compose stack does not publish unauthenticated monitoring externally by default.
- [x] 1.3 Replace unsigned runtime SPIRE binary downloads with pinned local artifacts or mandatory integrity verification.
- [x] 1.4 Add or update focused compose/bootstrap tests or render checks that prove the new defaults.

## 2. Validation
- [x] 2.1 Run `openspec validate harden-docker-compose-secret-defaults-and-bootstrap-integrity --strict`.
- [x] 2.2 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.3 Run `git diff --check`.
