## Context
The SNMP checker runs as an embedded collector inside `serviceradar-agent`, but build and deployment tooling still treats it as a standalone component. Several legacy Go packages appear tied to the retired Golang core and may be unused.

## Goals / Non-Goals
- Goals:
  - Remove unused Go packages and clean build definitions.
  - Remove standalone SNMP checker build, image, and deployment artifacts.
  - Keep embedded SNMP functionality in `serviceradar-agent` intact.
- Non-Goals:
  - Changes to SNMP collection behavior or protocol support.
  - New features or refactors beyond cleanup/removal.

## Decisions
- Decision: Treat SNMP checker as an internal library only; no standalone service artifacts.
- Decision: Delete legacy Go packages only after verifying no active references (including tests, tools, or scripts).

## Risks / Trade-offs
- Risk: Hidden references in tooling/build scripts could break CI or releases.
  - Mitigation: Search build files, Docker/Helm, and CI scripts; run targeted builds/tests.

## Migration Plan
- Remove build/packaging/deployment artifacts.
- Update build definitions.
- Validate that `serviceradar-agent` still builds and that no Docker/Helm references to SNMP checker remain.

## Open Questions
- Do any non-obvious tools (scripts, CI jobs) still depend on `pkg/db` or SNMP checker artifacts?
