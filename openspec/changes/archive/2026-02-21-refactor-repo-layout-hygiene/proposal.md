# Change: Refactor Repository Layout Hygiene

## Why
Issue #2851 identifies widespread repository layout drift that makes ownership unclear, slows onboarding, and increases build/release maintenance cost. The current structure mixes language boundaries and build artifacts, which makes large refactors risky and difficult to execute safely.

## What Changes
- Define and enforce a canonical top-level layout for language/runtime ownership:
  - `go/` for Go application code (`cmd/`, `pkg/`, `internal/` migrations into one tree)
  - `elixir/` for Elixir apps (including consolidating `web-ng` into `elixir/`)
  - `rust/` as the only location for Rust code
  - `database/` for AGE/Timescale and related database assets
  - `build/` for build-only assets where applicable
  - `contrib/` for optional integrations/plugins/snmp artifacts
- Re-home scattered directories called out in #2851 (`cmd/`, `pkg/`, `internal/`, `scripts/`, `plugins/`, `snmp/`, `release/`, `third_party`, `alias`, and selected build assets).
- Update Bazel, Make, module/workspace references, and CI paths so builds and tests continue to pass from the new locations.
- Add a staged migration strategy that prioritizes deterministic moves, temporary compatibility shims where needed, and explicit cleanup of obsolete paths.
- Document the final layout and migration steps in repo docs.

## Impact
- Affected specs: `repository-layout` (new)
- Affected code: top-level repo layout, Bazel targets, Make targets, Go module paths/imports, Elixir project paths, Rust crate references, CI scripts, release/packaging assets, developer documentation.
- Breaking impact: path-level breaking changes for contributors and tooling; proposal requires transition safeguards and explicit migration documentation.
