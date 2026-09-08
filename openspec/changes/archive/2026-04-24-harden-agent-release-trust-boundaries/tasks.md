## 1. Implementation
- [x] 1.1 Remove package-managed agent environment override support for the release verification key, updater path, runtime root, and seed binary path.
- [x] 1.2 Validate the package-owned updater binary before executing release activation.
- [x] 1.3 Harden the package-managed launcher and systemd unit so trust-sensitive paths are not sourced from `/etc/serviceradar/kv-overrides.env`.
- [x] 1.4 Stop edge onboarding bundles from writing the managed release verification key override for package-managed agents.
- [x] 1.5 Add focused Go tests for fixed trust-anchor/path behavior and updater validation failure cases.
- [x] 1.6 Update release-management and onboarding documentation to describe the new trust boundary and migration path.

## 2. Validation
- [x] 2.1 Run focused agent package tests covering release staging/activation hardening.
- [x] 2.2 Run focused onboarding tests covering the removal of release-key override persistence.
- [x] 2.3 Run `openspec validate harden-agent-release-trust-boundaries --strict`.
