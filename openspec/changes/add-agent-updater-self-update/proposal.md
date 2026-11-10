# Change: Let the agent's privileged updater be replaced without an OS package upgrade

## Why

The Linux agent runs unprivileged and updates itself: it stages a verified release under
`/var/lib/serviceradar/agent/versions/<version>` and a `current` link selects it
(`go/pkg/agent/release_update.go:253`, `go/pkg/agent/release_runtime.go:107`). Everything
that needs root goes through one setuid-root helper, `/usr/local/bin/serviceradar-agent-updater`
(`go/pkg/agent/release_runtime.go:38`), which the OS package installs with mode `4750`
(`build/packaging/packages.bzl:46`, `build/packaging/specs/serviceradar-agent.spec:36`).
That helper activates releases, installs and removes native add-on systemd units, applies
file capabilities, relabels add-on binaries and installs managed certificates
(`go/cmd/agent-updater/main.go:50`).

Nothing but the package ever writes that file. Self-update does not replace it and the
release payload does not contain it; the flag contract says so in as many words
(`go/pkg/agent/updaterflags/flags.go:21`). Every privileged capability added after a host's
package was installed is therefore unreachable on that host until someone upgrades the
package by hand:

- Systemd add-on installs need updater flags an old helper does not define. The agent
  detects this by parsing the helper's `--help` text
  (`go/pkg/agent/release_runtime.go:468`), reports
  `addon.systemd.updater.unavailable` (`go/pkg/agent/push_loop_capabilities.go:359`), and
  core marks the target ineligible with `agent_updater_outdated`
  (`elixir/serviceradar_core/lib/serviceradar/plugins/addon_rollout_artifact.ex:185`).
  That contains the damage. It does not repair the host.
- Managed certificate operations have the same dependency
  (`go/pkg/agent/managed_certificates.go:93`).
- The capability bounding set the helper inherits comes from the packaged unit
  (`build/packaging/agent/systemd/serviceradar-agent.service:40`), so it ages the same way.

The observed result is a fleet whose agents are current and whose privileged helpers are
many releases old, with add-on delivery failing on most bare-metal hosts and no in-product
path to fix it.

## What Changes

- **Self-replacement.** The installed root updater gains one new privileged operation:
  replace itself with a newer updater. The unprivileged agent stages the candidate and its
  signed descriptor; the root updater verifies both and performs the replacement. The agent
  never writes the privileged path and never chooses the destination, owner or mode.
- **A signed, typed updater descriptor.** Each agent release publishes, per OS and
  architecture, an updater binary and a small descriptor that binds component kind,
  version, platform and SHA-256. The descriptor is signed over a domain-separated message
  with a dedicated updater key whose public half is compiled into the updater. An add-on
  signature or an agent release manifest signature can never be replayed as an updater
  signature.
- **Rollback protection.** A replacement must be strictly newer than the installed updater
  and not below a root-owned version floor. Downgrade happens only through the package
  manager, by a root operator.
- **Crash-safe replacement.** The candidate is written to a root-only temporary file in
  the destination directory, self-tested by the running updater, given its final owner,
  mode and security label, and published with one `rename(2)`. An interrupted replacement
  leaves the previous updater in place.
- **Machine-readable self-description.** The updater reports its version, platform and
  supported operations as JSON. The agent stops inferring capability from help text.
- **Package changes that stop regressions.** The package ships its updater as a
  package-owned, non-setuid payload and installs it to the active path only when it is not
  older than what is already there, so a package reinstall cannot regress a host and
  `rpm -V` / `dpkg --verify` stay clean.
- **The updater reconciles the host contract it depends on**: a managed systemd drop-in
  for the service properties its operations need, extending the drop-in mechanism that
  already exists (`go/pkg/agent/release_runtime.go:171`).
- **Per-agent updater state in core and web-ng**: version, state, reason and supported
  operations; fleet filters; the exact one-time remedy for hosts whose helper predates
  self-replacement; updater outcome on release and add-on rollouts.
- **Rollout control as runtime settings** with code defaults: a kill switch and a pause
  rule, stored in the database and not in Helm values.
- **The bootstrap is stated, not hidden.** Helpers already in the field cannot replace
  themselves. Those hosts need one package upgrade. The product names each such host, says
  why, and gives the remedy.

No **BREAKING** change for operators. Two approved statements are amended and called out
in `design.md`: the documentation line that "baseline updater assets remain package-owned"
(`docs/docs/agent-release-management.md:282`) and the flag-contract comment that installed
updaters "are upgraded by the OS package, not by an agent self-update"
(`go/pkg/agent/updaterflags/flags.go:21`).

## Impact

- Affected specs: `agent-release-management` (new requirements; existing requirements
  unchanged), `agent-registry`, `build-web-ui`.
- Affected code: `go/cmd/agent-updater`, `go/pkg/agent` (updater command, release runtime,
  capability reporting, control stream), `go/pkg/agent/updaterflags`, `build/release`
  (publisher and manifest), `build/packaging` (deb, rpm, postinstall, spec), the release
  workflow, `elixir/serviceradar_core/lib/serviceradar/edge` (release manager, rollout
  targets, settings), `ServiceRadar.Infrastructure.Agent`, add-on eligibility
  (`ServiceRadar.Plugins.AddonRolloutArtifact`), web-ng agent and rollout views, and the
  agent release, platform package and native add-on documentation.
- Related open changes: `add-native-addon-delivery-models`, `add-native-addon-edge-ops`,
  `refactor-addon-lifecycle-operability`, `fix-stuck-addon-rollouts` and
  `add-managed-component-certificates` all assume a root-owned updater and stay valid; this
  change keeps the helper root-owned at the same path. `add-windows-agent-installer`
  records that the updater is systemd-based; Windows and macOS stay out of scope here.
- Related proposal: `add-awx-playbook-provisioning` supplies the "Install or upgrade the
  ServiceRadar agent package" automation that is one of the bootstrap remedies. Neither
  change depends on the other to ship.
