# Change: Optimize Elixir release build performance

## Why
The BuildBuddy invocation `5f37344e-496c-4f50-8e2a-6af1c24b9e30` showed that the main bottleneck in the container build flow is no longer top-level image orchestration. The slowest work is inside the Bazel `mix_release` actions for `serviceradar_agent_gateway`, `serviceradar_core_elx`, and `serviceradar_web_ng`.

Those release actions still perform heavyweight bootstrap steps inside a single action:
- `mix local.hex --force`
- `mix local.rebar --force`
- `mix deps.get --only prod`
- `mix deps.compile`
- `bun install` for web-ng assets
- `mix tailwind`, `mix esbuild`, React server bundle generation

That shape is expensive, weakly cacheable, and partially dependent on live registry or git fetches even though Bazel should be driving a more reproducible release path.

## What Changes
- Refactor the Bazel `mix_release` rule so Elixir release actions stop doing avoidable dependency/bootstrap work inside the release action.
- Split each Bazel `mix_release` into a cached dependency-bootstrap action and a final release-packaging action so dependency work is isolated behind its own Bazel action key.
- Key the dependency-bootstrap action off narrow project manifest/config inputs plus shared path-dependency sources, instead of the full application source tree.
- Use a stable workdir layout so the bootstrapped Mix `_build` and `deps` state can be restored by the final release action without breaking relative path dependencies.
- Remove the committed Hex cache tarball from the default Bazel remote path and rely on executor-local caching while follow-on dependency work lands.
- Reduce repeated dependency compilation and tool installation across Elixir release targets.
- Document and isolate any remaining inputs that force web-ng releases to depend on other image outputs, and remove the current core digest coupling from the web image path.

## Impact
- Affected specs: `container-image-builds`, `web-ng-build`
- Affected code:
  - `build/mix_release.bzl`
  - `build/BUILD.bazel`
  - `elixir/web-ng/BUILD.bazel`
  - `elixir/serviceradar_core_elx/BUILD.bazel`
  - `elixir/serviceradar_agent_gateway/BUILD.bazel`
  - `elixir/web-ng/mix.exs`
  - supporting docs for Bazel release builds
