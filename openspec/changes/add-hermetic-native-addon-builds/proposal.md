# Change: Hermetic native add-on build gates

## Why
The native add-on signing work adds the right release gates, but several of those
gates still rely on host-installed tools, shell-composed artifact discovery, and the
runner's ambient platform. That makes local validation fragile and lets CI drift as
the runner image changes.

## What Changes
- Move native add-on build, hygiene, size, and verifier-negative gates behind
  canonical Bazel targets with declared inputs and tools.
- Pin build-gate tools such as `go-size-analyzer`, `oras`, `cosign`, `jq`, and
  the add-on signature verifier through Bazel-managed tool targets or repository
  rules instead of workflow-time installs.
- Make native add-on binary and gate execution use an explicit Linux exec/target
  platform so macOS workstations and Linux CI do not accidentally select different
  Go SDKs or host tools.
- Keep publish/sign operations networked, but make their pre-release verifier tests
  run against deterministic fixture OCI layouts without remote registry access.

## Impact
- **Depends on:** `add-native-addon-build-signing` for the native add-on signing,
  verifier, size, and dead-code gate scripts that this change hermeticizes.
- **Affected specs:** `native-addon-builds`.
- **Affected code:** `build/native_addons/` Bazel rules and aggregate targets;
  `MODULE.bazel`/lockfile tool pinning; native add-on gate scripts; Forgejo native
  add-on workflow; any tool-wrapper scripts needed to pass Bazel-provided paths.
- **Non-goal:** Fully offline publishing. Harbor/Cosign/Rekor publishing still
  requires network and secrets; this change only makes the build and pre-release
  validation stages hermetic.
