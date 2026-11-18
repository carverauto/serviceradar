# Change: Report the privileged updater's version and name the hosts that need a package upgrade

## Why

The Linux agent updates itself, but the setuid-root helper it calls for every privileged
operation, `/usr/local/bin/serviceradar-agent-updater`, is written only by the OS package
(`go/pkg/agent/updaterflags/flags.go`, `build/packaging/packages.bzl`). A host whose agent
is current can therefore run a helper many releases old, and the product cannot say so:

- The helper cannot report its own version. `--version` names the staged release to
  activate.
- The agent infers what the helper can do by parsing flag names out of its `--help` text
  (`go/pkg/agent/release_runtime.go`), and reports one capability string,
  `addon.systemd.updater.unavailable`, when a flag is missing. Core turns that into
  `agent_updater_outdated` (`ServiceRadar.Plugins.AddonRolloutArtifact`).
- A helper that has every flag but an old behaviour passes that probe. Commit
  `07c68ff5b8` changed how the helper clears a failed unit. Hosts whose helper predated it
  accepted add-on rollouts, failed them one by one, rolled back, and paused the rollout.
  Nothing on the fleet view said the cause was the helper, and the only way to find the
  affected hosts was to inspect the binary on each one.
- The remedy, upgrading the `serviceradar-agent` package, is not stated anywhere in the
  product for the hosts that need it.

`add-agent-updater-self-update` proposed closing this gap by letting the installed helper
replace itself on command from the control plane. The product owner has declined that
direction: a root program that can be replaced remotely is a larger risk than the
problem it solves. That change is parked. This change takes the part of it that needs no
remote write to the privileged path, and states the package as the only way the helper
changes.

## What Changes

- **The helper describes itself.** A new invocation prints the helper's version,
  platform and named operations as JSON and makes no privileged change.
- **Each agent release declares the helper it needs**: a minimum helper version and the
  operations its features use. The minimum is raised only when a helper fix or operation
  matters to the agent, so an ordinary agent release does not ask for a package upgrade.
  It is never below the first helper version that answers self-description, so the
  package upgrade it names installs a helper that can be reported `current`.
- **The agent reports a helper state**: `current`, `package_upgrade_required`,
  `unavailable` or `not_applicable`, with the version, operations, reason and observation
  time. Core records `unknown` for an agent that reports nothing.
- **Privileged features are gated by named operation**, so the agent reports a blocked
  feature with the missing operation, and never calls the helper with a flag it does not
  define.
- **Rollouts exclude stale hosts before dispatch.** An add-on or managed-certificate
  target whose helper is below the release's minimum is ineligible up front, and the row
  names the agent and the package upgrade. A target whose helper is unavailable is
  excluded too, with the failed safety check and a package reinstall or repair as its
  remedy. A target whose helper meets the minimum but lacks a needed operation is
  excluded with `updater lacks operation <name>` and a package reinstall as its remedy.
  None is attempted, failed and rolled back.
- **The fleet view names the hosts and the remedy**: a filter and count by helper state,
  a notice while any host needs a package upgrade, and per host the package command for
  its package family with the required helper version, plus the fleet-wide route through the
  agent package playbooks.
- **The package stays the only writer of the helper.** This is stated as a requirement:
  no control-plane command, agent release or add-on changes the privileged helper.

Not in this change: any remote replacement of the helper, the signed updater descriptor,
the version floor, and the package payload layout. Those remain in the parked
`add-agent-updater-self-update`.

## Impact

- Affected specs: `agent-release-management`, `agent-registry`, `build-web-ui` (new
  requirements; existing requirements unchanged).
- Affected code: `go/cmd/agent-updater` (self-description), `go/pkg/agent` (helper
  inspection, capability status, feature gating), `go/pkg/agent/updaterflags`,
  `ServiceRadar.Infrastructure.Agent` and the agent read actions, add-on eligibility
  (`ServiceRadar.Plugins.AddonRolloutArtifact`, `AddonRolloutCoordinator`,
  `AddonProfileReconciler`), web-ng agent and rollout views, and the agent release,
  platform package and Ansible documentation.
- Hosts already in the field: a helper installed before this change does not answer the
  self-description invocation, so it is reported `package_upgrade_required` until its
  package is upgraded once. That is the intended result, and it is the same package
  upgrade those hosts need today.
- Related changes: `add-agent-updater-self-update` (parked; its status, self-description,
  operation gating, eligibility and remedy requirements moved here),
  `add-awx-playbook-provisioning` (supplies the "install or upgrade the agent package"
  automation the remedy links to; neither change depends on the other),
  `fix-stuck-addon-rollouts` (names the evidence on a paused rollout; this change keeps
  a stale-helper host from entering the rollout at all).
