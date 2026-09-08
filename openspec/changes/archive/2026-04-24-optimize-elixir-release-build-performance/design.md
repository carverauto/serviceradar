## Context
The previous image-orchestration change established canonical aggregate targets for image build and push workflows. After that change, BuildBuddy invocation `5f37344e-496c-4f50-8e2a-6af1c24b9e30` still took almost 13 minutes.

The invocation data points to a different bottleneck:

- Bazel executed many actions in parallel (`122 remote`, `6893 action cache hit`).
- The critical path was still long (`544.71s`) because a few Elixir `mix release` actions dominate the build.
- The three large release actions for `serviceradar_agent_gateway`, `serviceradar_core_elx`, and `serviceradar_web_ng` appear as large monolithic actions with substantial internal serial work.

The current `mix_release` rule in `build/mix_release.bzl` confirms why:

- It copies the source tree into a temp workdir.
- It bootstraps Mix tooling with `mix local.hex` and `mix local.rebar` when not already present.
- It runs `mix deps.get --only prod`.
- It runs `mix deps.compile`.
- For `web_ng`, it also runs `bun install` in `assets/` and `assets/component/`, then runs Tailwind, esbuild, React server bundling, and `phx.digest`.
- It then runs `mix release`.

That makes each release action a catch-all build step instead of a narrowly scoped, cache-friendly release packaging action.

## Current State Analysis
Relevant targets:

- `//elixir/web-ng:release_tar`
- `//elixir/serviceradar_core_elx:release_tar`
- `//elixir/serviceradar_agent_gateway:release_tar`

All three use the same custom Bazel rule:

- `mix_release` in `build/mix_release.bzl`

The current high-cost characteristics are:

- dependency resolution and compilation happen inside every release action
- the rule still relies on live Hex/Rebar resolution on cold executors
- web-ng asset dependencies are installed at release time with `bun install`
- web-ng uses a git dependency (`permit_ecto`) which causes additional fetch behavior
- release actions compile Rust NIFs as part of the same monolithic action

This makes cache misses expensive and reduces the chance that separate release targets can share more intermediate work.

## Goals / Non-Goals
- Goals:
  - remove avoidable network/bootstrap work from Elixir release actions
  - improve cacheability and reproducibility of Bazel-driven Elixir releases
  - reduce repeated work across `web_ng`, `core_elx`, and `agent_gateway`
  - keep the release outputs and runtime behavior unchanged
- Non-Goals:
  - changing application behavior or release contents
  - redesigning Ash or Phoenix application architecture
  - solving all Rust NIF compilation cost in the same pass unless it directly blocks release build improvements
  - changing image tags or push workflows

## Decisions
- Decision: Remove the committed Hex cache tarball from the normal remote build path.
  - The repo-level tarball is manual to refresh, easy to forget, and not a good long-term contract for remote builds.
  - Executor-local cache state under `/cache` is the better short-term acceleration layer while dependency bootstrap is refactored.

- Decision: Split `mix_release` into two Bazel actions before adding new public BUILD targets.
  - The smallest safe change is to keep the existing `//elixir/...:release_tar` interface, but generate an intermediate dependency-bootstrap archive inside the rule.
  - That makes `mix local.hex`, `mix local.rebar`, `mix deps.get`, patching, and `mix deps.compile` independently cacheable without broadening the BUILD API.
  - The three Elixir apps do not share identical lockfiles, so a single compiled dependency tree across all three would be brittle.
  - Each app should provide a narrow `bootstrap_srcs` input set (Mix manifests plus config) so ordinary application code edits do not invalidate dependency bootstrap.
  - The rule should use a stable workdir name per app and recreate the sibling path-dependency layout expected by `path: "../..."` Mix deps.

- Decision: Optimize web-ng separately where needed, but keep one proposal.
  - `web_ng` has the heaviest path because it includes asset and React bundle work in addition to Elixir compilation.
  - The generic `mix_release` rule likely needs common improvements, while `web_ng` may need web-specific splitting or prebuild targets.

- Decision: Remove the current `web_ng -> core digest` dependency.
  - The dependency only exists to stamp `coreBuildId` into static build metadata.
  - `web_ng` release packaging should not wait on a separate image digest when the web release itself does not require it for correctness.

## Candidate Optimization Areas
1. Replace cold-start live Hex/Rebar work with a better bootstrap mechanism than a committed repo tarball.
2. Replace `mix deps.get` inside the release action with a dedicated dependency-bootstrap action keyed by each app's manifests, config, and shared path-dependency sources.
3. Avoid `bun install` inside `web_ng` release actions by precomputing or vendoring the JS dependency state Bazel needs.
4. Split asset compilation from release packaging where Bazel can cache the outputs separately.
5. Audit git dependencies, especially `permit_ecto`, because they worsen reproducibility and cache behavior.
6. Reduce duplicated release work across the three Elixir apps when shared local path deps are unchanged.

## Risks / Trade-offs
- Removing the repo tarball means cold executors still pay live dependency/bootstrap cost until follow-on work lands.
  - Mitigation: lean on executor-local `/cache` now, then split dependency preparation from final release assembly.

- Splitting asset or dependency preparation into more Bazel targets may increase rule complexity.
  - Mitigation: prefer a small number of reusable intermediate targets over one-off service rules.

- Tightening hermeticity may surface hidden assumptions in current Mix aliases or dependency declarations.
  - Mitigation: migrate incrementally and validate each Elixir release target independently.

## Migration Plan
1. Measure the current `mix_release` action shape and identify which bootstrap steps are still live or redundant.
2. Refactor `mix_release` so dependency bootstrap is produced by its own Bazel action and consumed by final release packaging.
3. Introduce a more cacheable asset build path for `web_ng`.
4. Re-run the three release targets and the aggregate image build to compare critical path and elapsed time.
5. Document the remaining intentional dependencies, including any `web_ng` build-info coupling to core images.

## Open Questions
- Should Hex/Rebar state be vendored into Bazel inputs, bootstrapped via executor image contents, or handled by a dedicated intermediate Bazel target?
- Can `web_ng` asset outputs become separate Bazel targets consumed by `mix_release` instead of being built inside it?
- Is the `permit_ecto` git dependency acceptable in the medium term, or should it be replaced with a packaged dependency source?
- Can build-info generation stop depending on the final core image digest without losing needed metadata?
