# Change: Harden package-managed agent release trust boundaries

## Why
The managed agent release path currently trusts host-local environment overrides for the release verification key, updater binary path, runtime root, and seed binary path. That weakens the intended trust boundary for package-managed agents because a local configuration write can redirect execution or redefine the trust anchor used for release verification.

The older SR-2026-001 security finding is directionally correct: once package-managed trust-sensitive paths and keys are overrideable through `/etc/serviceradar/kv-overrides.env` or inherited process environment, the managed rollout mechanism no longer relies solely on package-owned artifacts.

## What Changes
- Remove package-managed agent runtime support for environment-based overrides of:
  - `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
  - `SERVICERADAR_AGENT_UPDATER`
  - `SERVICERADAR_AGENT_RUNTIME_ROOT`
  - `SERVICERADAR_AGENT_SEED_BINARY`
- Require the managed agent to trust only the build-time embedded release verification key for manifest validation.
- Require updater activation to execute only the package-owned updater path after validating that the binary is a regular file, owned by `root`, and not group/world writable.
- Keep the mutable runtime payload rooted at the package-owned runtime directory instead of allowing host-local redirection through environment variables.
- Remove release public key distribution through edge onboarding bundle overrides for package-managed agents.
- Update operator docs and migration guidance for fleets that still carry stale release-key entries in `/etc/serviceradar/kv-overrides.env`.

## Impact
- Affected specs:
  - `agent-release-management`
  - `edge-onboarding`
- Affected code:
  - `go/pkg/agent/release_update.go`
  - `go/pkg/agent/release_runtime.go`
  - `go/pkg/agent/control_stream.go`
  - `build/packaging/agent/bin/serviceradar-agent`
  - `build/packaging/agent/systemd/serviceradar-agent.service`
  - edge onboarding bundle generation and enrollment docs/tests
- Breaking behavior:
  - Package-managed agents will no longer honor those local environment overrides for release trust and runtime path selection.
