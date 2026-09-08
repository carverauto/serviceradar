## Context
Managed agent rollout already assumes a package-owned trust boundary: the package installs the launcher, updater, seed binary, and service unit, while mutable payloads live under `/var/lib/serviceradar/agent`. The current implementation weakens that model by allowing runtime environment variables to override the updater path, seed binary path, runtime root, and release verification key.

That override chain is especially problematic because `/etc/serviceradar/kv-overrides.env` is intentionally general-purpose and can be merged by enrollment workflows. As soon as trust-sensitive release inputs are accepted from that file, local configuration becomes equivalent to modifying the managed release trust anchor.

## Goals / Non-Goals
- Goals:
  - Ensure package-managed agent release trust anchors come only from package-owned artifacts.
  - Ensure updater activation only executes a package-owned updater binary.
  - Remove host-local redirection of release runtime storage for package-managed agents.
  - Stop onboarding from writing managed release trust state into the generic overrides file.
- Non-Goals:
  - Replacing the generic `kv-overrides.env` mechanism for unrelated runtime configuration.
  - Changing control-plane release signing or control-plane verification behavior.
  - Solving trust rotation for arbitrary unmanaged binaries outside the package-managed fleet model.

## Decisions
- Decision: Package-managed agents trust only `ReleaseSigningPublicKey` embedded at build time.
  - Rationale: the public verification key is a trust anchor, not mutable runtime configuration.
- Decision: Package-managed agents use fixed package-owned paths for updater, seed binary, and runtime root.
  - Rationale: these paths directly govern what code executes and where staged runtimes are loaded from.
- Decision: The agent validates the updater binary before execution.
  - Rationale: even with a fixed path, the agent should fail closed if the package-owned updater has been replaced with an unsafe file.
- Decision: Edge onboarding stops persisting `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` into `/etc/serviceradar/kv-overrides.env` for package-managed agent bundles.
  - Rationale: onboarding should not mutate the managed release trust anchor once the package embeds it.

## Risks / Trade-offs
- Existing fleets that still rely on `/etc/serviceradar/kv-overrides.env` for the release key will need migration guidance.
  - Mitigation: document a one-time upgrade path to a package version that embeds the correct key.
- Some local developer workflows may currently rely on environment overrides for release-path testing.
  - Mitigation: keep test-only explicit function parameters and fixtures, but remove host runtime override behavior in packaged paths.
- Updater ownership validation may fail on incorrectly packaged or manually modified hosts.
  - Mitigation: surface a specific activation error so operators can repair the package installation.

## Migration Plan
1. Ship a package-managed agent release that embeds the active release verification key.
2. Document that fleets with stale `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` entries may need one last repair/re-enrollment/package refresh before upgrading into the hardened model.
3. After the hardened package is installed, future managed rollouts rely on package-owned trust anchors instead of local override files.

## Open Questions
- Should the updater validation require `uid == 0` only, or also validate the containing directory ownership/mode?
- Should the launcher also refuse to start if the package-owned seed binary fails the same ownership/writability checks?
