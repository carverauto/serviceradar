## 1. Analyzer Baseline

- [x] 1.1 Confirm the managed-app scope and current analyzer coverage for every first-party Mix project under `elixir/`
- [x] 1.2 Add or update Mix dependencies, aliases, and config needed to run formatting checks, compile-time warning checks, xref reporting, strict Credo, dependency audits, Dialyzer, and Phoenix security checks where applicable across the `elixir/` workspace
- [x] 1.3 Add version-controlled exclusions and temporary waivers for generated, vendored, or intentionally deferred analyzer targets

## 2. CI Enforcement

- [x] 2.1 Replace or consolidate the existing narrow Elixir lint workflows with a matrix-style workflow or reusable workflow pattern that runs the full analyzer suite across the `elixir/` workspace
- [x] 2.2 Ensure Phoenix projects run Sobelow and non-Phoenix projects skip Phoenix-only analyzers without weakening the shared baseline
- [x] 2.3 Add dependency and PLT caching or other reuse needed to keep analyzer runtime practical

## 3. Baseline Cleanup

- [x] 3.1 Run the analyzer suite locally for each managed Mix project under `elixir/`
- [x] 3.2 Fix or explicitly suppress existing findings required to reach a stable green baseline
- [x] 3.3 Verify local documented commands and CI jobs execute the same analyzer sequence

## 4. Documentation

- [x] 4.1 Document the standard Elixir analyzer contract and local usage in repo docs
- [x] 4.2 Record the deferred issue #3029 candidates (`Styler`, `Boundary`, `rustywind`, `ex_dna`, `ex_slop`) as follow-up evaluation work
