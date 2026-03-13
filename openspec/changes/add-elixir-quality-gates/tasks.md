## 1. Analyzer Baseline

- [ ] 1.1 Confirm the managed-app scope and current analyzer coverage for every first-party Mix project under `elixir/`
- [ ] 1.2 Add or update Mix dependencies, aliases, and config needed to run the standard analyzer suite across the `elixir/` workspace
- [ ] 1.3 Add version-controlled exclusions for generated, vendored, or intentionally deferred analyzer targets

## 2. CI Enforcement

- [ ] 2.1 Expand existing Elixir workflows and add any new workflows needed to run the full analyzer suite across the `elixir/` workspace
- [ ] 2.2 Ensure Phoenix projects run Sobelow and non-Phoenix projects skip Phoenix-only analyzers without weakening the shared baseline
- [ ] 2.3 Add dependency and PLT caching or other reuse needed to keep analyzer runtime practical

## 3. Baseline Cleanup

- [ ] 3.1 Run the analyzer suite locally for each managed Mix project under `elixir/`
- [ ] 3.2 Fix or explicitly suppress existing findings required to reach a stable green baseline
- [ ] 3.3 Verify local documented commands and CI jobs execute the same analyzer sequence

## 4. Documentation

- [ ] 4.1 Document the standard Elixir analyzer contract and local usage in repo docs
- [ ] 4.2 Record the deferred issue #3029 candidates (`Styler`, `Boundary`, `rustywind`, `ex_dna`, `ex_slop`) as follow-up evaluation work
