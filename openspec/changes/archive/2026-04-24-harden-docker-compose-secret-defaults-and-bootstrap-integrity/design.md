## Context
The Docker Compose stack is used as a real runnable deployment profile in this repository, not just a throwaway dev helper. Some earlier hardening work removed static secrets from Helm, but the compose path still templates static defaults directly into runtime environment variables. The compose SPIRE bootstrap path also downloads executables from GitHub at container startup, which creates a supply-chain trust boundary after container execution has already begun.

## Goals / Non-Goals
- Goals:
  - ensure Docker Compose does not ship shared default secret material for runtime trust boundaries
  - keep compose-only operational UX workable by generating secrets automatically on first boot
  - prevent unauthenticated NATS monitoring exposure outside the compose network by default
  - remove unsigned runtime executable downloads from SPIRE bootstrap
- Non-Goals:
  - redesign the entire compose stack secret-management model
  - remove optional operator overrides for explicitly supplied secrets
  - replace SPIRE with a different identity runtime

## Decisions
- Decision: compose runtime secrets that define trust boundaries will be generated per install and stored in dedicated volumes/files.
  - Why: this preserves zero-touch boot while eliminating cross-install secret reuse.
- Decision: external NATS monitoring exposure will become explicit opt-in instead of default.
  - Why: the monitoring endpoint is operationally useful but should not be publicly reachable by default.
- Decision: SPIRE bootstrap will use pinned local binaries or verified artifacts instead of fetching and executing downloads at runtime without verification.
  - Why: runtime network fetch is the wrong place to establish trust for executables that become part of the local identity plane.

## Risks / Trade-offs
- Secret-generation bootstrap becomes slightly more complex.
  - Mitigation: keep generation centralized in existing compose bootstrap/update scripts and document operator overrides.
- Operators relying on host-published NATS monitoring may need an explicit override after the change.
  - Mitigation: document the override and treat it as an intentional debugging escape hatch.
- Baking or pinning SPIRE binaries may increase image size or bootstrap complexity.
  - Mitigation: keep the change scoped to compose-only assets and favor deterministic artifacts over dynamic download.

## Migration Plan
1. Introduce generated file-backed secrets for compose cluster/runtime signing values.
2. Rewire compose services to read generated secrets rather than static env defaults.
3. Restrict NATS monitoring exposure to internal-only or loopback by default, with explicit override support.
4. Replace runtime SPIRE downloads with pinned local binaries or add mandatory integrity verification if a local artifact path is still needed.

## Open Questions
- Whether the SPIRE bootstrap should move to a dedicated image layer or reuse an existing tools image with pinned binaries.
