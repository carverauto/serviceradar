## Context
Rust targets that depend on `openssl-sys` with vendored OpenSSL (`openssl-src`) transitively require Perl during OpenSSL build steps. The current Bazel wiring includes hermetic Perl source/tool targets, which can substantially increase cold build setup time.

## Goals / Non-Goals
- Goals:
- Reduce build latency and complexity by removing hermetic Perl as the default path where safe.
- Preserve reproducibility and provide a fallback for environments that require hermetic tooling.
- Keep behavior explicit and configurable.

- Non-Goals:
- Full replacement of OpenSSL with rustls in this change.
- Broad Rust dependency graph redesign outside the Perl/OpenSSL concern.

## Decisions
- Decision: Use host Perl as the default execution path for vendored OpenSSL build scripts in supported environments.
  - Rationale: Removes major bootstrap overhead while maintaining compatibility with OpenSSL build requirements.
- Decision: Preserve an explicit hermetic Perl fallback mode.
  - Rationale: Maintains policy compliance and reproducibility for restricted environments.
- Decision: Make strategy selection explicit via Bazel/module config and documented operator controls.
  - Rationale: Avoid implicit behavior differences between local and CI execution.

## Alternatives considered
- Keep hermetic Perl always-on: maximal hermeticity, poor developer ergonomics and high cold-build cost.
- Remove vendored OpenSSL entirely: likely larger migration/risk; out of scope for this change.
- Move to rustls immediately: desirable long-term, but broader security/compatibility analysis needed.

## Risks / Trade-offs
- Host Perl variability across environments may introduce subtle differences.
  - Mitigation: constrain supported versions, add CI checks, and keep hermetic fallback.
- Configuration drift between local and remote executors.
  - Mitigation: documented defaults plus explicit flags and validation in CI.

## Migration Plan
1. Add strategy controls and default selection.
2. Update build graph to skip hermetic Perl fetch/build in default mode.
3. Validate critical Rust targets in local and remote modes.
4. Update docs and roll out with rollback instructions.

## Open Questions
- Should CI default to host Perl or hermetic fallback for highest reproducibility?
- Which minimum Perl version should be guaranteed for supported environments?
- Do we need a dedicated presubmit check that ensures hermetic fallback remains functional?
