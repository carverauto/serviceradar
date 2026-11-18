## 1. Contract

- [ ] 1.1 Specify the self-description document (version, platform, operations) and the reason codes as a versioned contract shared by the helper, the agent and core.
- [ ] 1.2 Name the helper's existing operations (release activation, add-on systemd install, add-on systemd uninstall, managed certificates) and record them in `go/pkg/agent/updaterflags`.
- [ ] 1.3 Add the agent release's helper requirement (minimum version, operations per feature) as a compiled-in value, with the rule for when the minimum is raised written next to it; the minimum is never set below the first helper version that answers self-description.

## 2. Helper

- [ ] 2.1 Add the self-description invocation: JSON version, platform and operations, with no privileged side effect.
- [ ] 2.2 Stamp the helper's version at build time from the release version.

## 3. Agent

- [ ] 3.1 Report `not_applicable` without further checks on a platform whose installer provides no helper; otherwise apply the safety checks (present, regular file, root-owned, not group or world writable, setuid) before anything else and report `unavailable` with the failed check on any failure; then inspect a safe helper through self-description, and keep the help-text probe only to find the operations of a safe helper that does not answer it, which stays `package_upgrade_required` and rollout-ineligible.
- [ ] 3.2 Classify the helper state and report version (unknown for a helper that does not describe itself), required version, state, reason, operations and observation time in the capability status; keep reporting `addon.systemd.updater.unavailable` for older cores.
- [ ] 3.3 Gate privileged features on named operations and report a blocked feature with the missing operation instead of a flag error.
- [ ] 3.4 Report the host's package family (deb or rpm) and installed package version so the remedy can be exact.

## 4. Core

- [ ] 4.1 Persist per-agent helper status from the capability status, including required version, package family and installed package version; expose it through the agent read actions and SRQL.
- [ ] 4.2 Move add-on and managed-certificate eligibility from the capability string to helper state and required operations; keep the capability string as the fallback for agents that report `unknown`.
- [ ] 4.3 Record the ineligibility reason with the agent on the rollout target, replacing the bare `agent_updater_outdated`: the package upgrade and required version for `package_upgrade_required`, the failed safety check and a package reinstall or repair for `unavailable`; `updater lacks operation <name>` and a package reinstall for a `current` helper missing a declared operation.

## 5. Web UI

- [ ] 5.1 Agent detail: helper version, state, reason, operations, last observation.
- [ ] 5.2 Agents list: helper state column, filter and counts; Edge Ops notice while any agent is `package_upgrade_required` or `unavailable`.
- [ ] 5.3 Remedy panel: for `package_upgrade_required`, the package command built from the host's package family and the required version, and the fleet-wide playbook route; for `unavailable`, the failed safety check and a package reinstall or repair; for a `current` helper missing a declared operation, the operation and a package reinstall. A `package_upgrade_required` or `unavailable` helper keeps its own remedy even when its operation list is short.
- [ ] 5.4 Add-on and release rollout views name the agent, the reason and the remedy for targets excluded for their helper.

## 6. Tests

- [ ] 6.1 Helper: self-description output matches the build; the invocation runs as a non-root caller and changes nothing on the host.
- [ ] 6.2 Agent: each state is classified in order from a platform without a helper (`not_applicable`, no safety checks), an unsafe or missing helper where the installer provides one (`unavailable`, even if it answers), a safe one that does not answer or is below the minimum (`package_upgrade_required`), and a safe one that meets the minimum (`current`), including one missing an operation; a gated feature never invokes an undefined flag.
- [ ] 6.3 Core: read model, including `unknown` for an agent that reports no status and never counted as healthy; eligibility for each state and for a `current` helper missing a declared operation; the fallback to the capability string.
- [ ] 6.4 LiveView: remedy panel, filters, counts and excluded rollout rows.

## 7. Documentation and validation

- [ ] 7.1 Update `docs/docs/agent-release-management.md`, `docs/docs/agent-platform-packages.md` and `docs/docs/native-addons.md`: the helper is package-owned, how its state is reported, and when a package upgrade is required.
- [ ] 7.2 Document the fleet-wide package upgrade through the agent package playbooks (`install-agent-debian.yml`, `install-agent-redhat.yml`) in `docs/docs/ansible.md`.
- [ ] 7.3 Run `openspec validate add-agent-updater-status-reporting --strict`, the focused Go and Elixir checks, and the required Bazel suite; report every check not run.
