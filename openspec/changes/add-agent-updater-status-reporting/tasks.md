## 1. Contract

- [ ] 1.1 Specify the self-description document (version, platform, operations) and the reason codes as a versioned contract shared by the helper, the agent and core.
- [ ] 1.2 Name the helper's existing operations (release activation, add-on systemd install, add-on systemd uninstall, managed certificates) and record them in `go/pkg/agent/updaterflags`.
- [ ] 1.3 Add the agent release's helper requirement (minimum version, operations per feature) as a compiled-in value, with the rule for when the minimum is raised written next to it.

## 2. Helper

- [ ] 2.1 Add the self-description invocation: JSON version, platform and operations, with no privileged side effect.
- [ ] 2.2 Stamp the helper's version at build time from the release version.

## 3. Agent

- [ ] 3.1 Inspect the helper through self-description; keep the help-text probe only to find the operations of a helper that does not answer it.
- [ ] 3.2 Classify the helper state and report version, state, reason, operations and observation time in the capability status; keep reporting `addon.systemd.updater.unavailable` for older cores.
- [ ] 3.3 Gate privileged features on named operations and report a blocked feature with the missing operation instead of a flag error.
- [ ] 3.4 Report the host's package family (deb or rpm) and installed package version so the remedy can be exact.

## 4. Core

- [ ] 4.1 Persist per-agent helper status from the capability status; expose it through the agent read actions and SRQL.
- [ ] 4.2 Move add-on and managed-certificate eligibility from the capability string to helper state and required operations; keep the capability string as the fallback for agents that report `unknown`.
- [ ] 4.3 Record the ineligibility reason with the agent and the package upgrade on the rollout target, replacing the bare `agent_updater_outdated`.

## 5. Web UI

- [ ] 5.1 Agent detail: helper version, state, reason, operations, last observation.
- [ ] 5.2 Agents list: helper state column, filter and counts; Edge Ops notice while any agent is `package_upgrade_required` or `unavailable`.
- [ ] 5.3 Remedy panel: package command for the host's package family with the target version, and the fleet-wide playbook route.
- [ ] 5.4 Add-on and release rollout views name the agent and the reason for targets excluded for their helper.

## 6. Tests

- [ ] 6.1 Helper: self-description output matches the build; the invocation runs as a non-root caller and changes nothing on the host.
- [ ] 6.2 Agent: each state is classified from a helper that answers, one that does not, one below the minimum, one missing an operation, an unsafe or missing one, and a platform without one; a gated feature never invokes an undefined flag.
- [ ] 6.3 Core: read model, including `unknown` for an agent that reports no status and never counted as healthy; eligibility for each state; the fallback to the capability string.
- [ ] 6.4 LiveView: remedy panel, filters, counts and excluded rollout rows.

## 7. Documentation and validation

- [ ] 7.1 Update `docs/docs/agent-release-management.md`, `docs/docs/agent-platform-packages.md` and `docs/docs/native-addons.md`: the helper is package-owned, how its state is reported, and when a package upgrade is required.
- [ ] 7.2 Document the fleet-wide package upgrade through the agent package playbooks (`install-agent-debian.yml`, `install-agent-redhat.yml`) in `docs/docs/ansible.md`.
- [ ] 7.3 Run `openspec validate add-agent-updater-status-reporting --strict`, the focused Go and Elixir checks, and the required Bazel suite; report every check not run.
