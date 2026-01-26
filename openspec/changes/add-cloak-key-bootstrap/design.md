## Context
CLOAK_KEY is required for AshCloak encryption. Docker Compose currently sets `CLOAK_KEY` to a blank string, which overrides the file-based key and crashes core-elx. Helm and Kubernetes manifest installs can also ship empty or placeholder values that bypass generation, leaving the platform unable to start.

## Goals / Non-Goals
- Goals:
  - Guarantee a valid base64-encoded 32-byte CLOAK_KEY for Docker Compose, Helm, and Kubernetes manifest installs.
  - Preserve operator-supplied keys across upgrades (no unintended rotation).
  - Fail fast or regenerate when the key is missing/empty/invalid.
- Non-Goals:
  - Automated key rotation or re-encrypting existing data.
  - Changing the underlying encryption algorithm or AshCloak behavior.

## Decisions
- Treat empty `CLOAK_KEY` values as missing so file-based keys are used.
- Secret generator jobs validate `cloak-key` and regenerate it when missing/empty/invalid.
- Docker Compose relies on the generated key file and avoids setting a blank `CLOAK_KEY` env var.

## Risks / Trade-offs
- Regenerating an invalid/placeholder key could make any previously encrypted data unreadable, but this should only affect deployments that were already broken.

## Migration Plan
- On upgrade, generator jobs only change `cloak-key` when it is missing/empty/invalid; valid keys are preserved.
- Document override guidance for operators who need a fixed key.

## Open Questions
- Should we surface a warning event in core/web when a regenerated key is detected?
