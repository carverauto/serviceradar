## 1. Analysis
- [x] 1.1 Document the current `mix_release` rule behavior and identify the expensive bootstrap steps inside each release action.
- [x] 1.2 Confirm which release targets are on the critical path for aggregate image builds.
- [x] 1.3 Identify which inputs are still fetched or installed dynamically during release builds.

## 2. Rule Refactor
- [x] 2.1 Remove or reduce live Hex/Rebar bootstrap from Bazel release actions.
- [x] 2.2 Introduce a reproducible input strategy for dependency resolution and compilation.
- [x] 2.3 Refactor web-ng asset preparation so `bun install` and related asset work are more cacheable.
- [x] 2.4 Review and reduce unnecessary cross-target coupling in Elixir image build metadata generation.

## 3. Validation
- [x] 3.1 Validate the OpenSpec change with `openspec validate optimize-elixir-release-build-performance --strict`.
- [ ] 3.2 Compare Bazel timings for the three Elixir release targets before and after the refactor.
- [ ] 3.3 Verify release contents and image builds remain functionally unchanged.
