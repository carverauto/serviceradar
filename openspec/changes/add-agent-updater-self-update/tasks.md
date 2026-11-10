## 1. Decisions and contracts

- [ ] 1.1 Owner resolves the Open Decisions in `design.md` (mechanism, key, A/B slots, package layout, kill-switch default, pause rule, drop-in scope, upgrade window, floor reset, bootstrap enforcement).
- [ ] 1.2 Specify the descriptor schema, the signed-message context string and the result/reason codes as a versioned contract shared by the publisher, the agent and the updater.
- [ ] 1.3 Confirm with a test that `ServiceRadar.Edge.ReleaseManifestValidator` and released agents accept a manifest carrying a top-level `updater` list; if either rejects it, publish the updater references outside the manifest instead.
- [ ] 1.4 Record the supported upgrade window that bounds updater flag and operation removal in `go/pkg/agent/updaterflags`.

## 2. Updater

- [ ] 2.1 Add `--describe`: JSON version, platform, operations, floor and state, with no privileged side effect.
- [ ] 2.2 Add the dedicated updater public key file, embedded at build time, with a release-time assertion that it matches the signing secret. The privileged path never reads a key from the environment.
- [ ] 2.3 Add `--updater-install`: no-follow bounded reads, signature over the domain-separated message, kind/platform/digest checks, rollback checks.
- [ ] 2.4 Add the root-owned state directory, the floor file, the exclusive lock and stale temporary-file cleanup.
- [ ] 2.5 Implement the replacement sequence: root-only temporary file in the destination directory, self-test, ownership then mode, label check, rename, directory sync, floor update.
- [ ] 2.6 Add `--updater-self-test`, including a signature test vector and a scratch replacement.
- [ ] 2.7 Add `--updater-install-from-package` for package install scripts, with the documented force flag.
- [ ] 2.8 Reconcile the updater-owned systemd drop-in and report `restart_pending` when it changed.
- [ ] 2.9 Emit stable reason codes for every refusal and failure.

## 3. Agent

- [ ] 3.1 Replace the help-text flag probe with `--describe`, keeping the probe as the fallback that classifies `bootstrap_required`.
- [ ] 3.2 Report updater version, state, reason, operations, floor and observation time in the capability status; keep reporting `addon.systemd.updater.unavailable` for older cores.
- [ ] 3.3 Stage the updater binary and descriptor through the existing release artifact transport and invoke the installed updater; handle `agent.update_updater` and the updater section of `agent.update_release` after a healthy activation.
- [ ] 3.4 Gate privileged features on named operations and report a blocked feature with the missing operation instead of a flag error.

## 4. Release pipeline and packages

- [ ] 4.1 Publish the updater binary, descriptor and signature per OS and architecture and reference them from the agent release manifest.
- [ ] 4.2 Add the updater signing secret to the release job only, and the derived-public-key assertion.
- [ ] 4.3 Add the successor gate: previous release's updater installs the candidate; the candidate installs a synthetic successor; both as a non-root caller in a container.
- [ ] 4.4 Ship the updater as a package-owned non-setuid payload on deb and rpm; install scripts call `--updater-install-from-package`; the active path becomes unpackaged (`%ghost` on rpm) and is removed on package removal.
- [ ] 4.5 Extend the package tests for payload mode, ghost entry, upgrade from a pre-change package, reinstall of an older package over a newer active updater, and clean `rpm -V` / `dpkg --verify` after a self-replacement.

## 5. Core

- [ ] 5.1 Persist per-agent updater status from the capability status; expose it through the agent read actions and SRQL.
- [ ] 5.2 Add the runtime settings (`updater_replacement_enabled`, `updater_replacement_pause_on_candidate_failure`) with code defaults; no Helm value.
- [ ] 5.3 Deliver the updater descriptor with `agent.update_release`; add `agent.update_updater` and reconcile `outdated` agents on the rollout cohort schedule.
- [ ] 5.4 Record updater outcome per rollout target; apply the pause rule by reason class.
- [ ] 5.5 Move add-on eligibility from the capability string to required operations; make an `outdated` updater a remediable state and keep `bootstrap_required` ineligible with its reason.
- [ ] 5.6 Emit audit events for dispatch, outcome, pause and kill-switch changes.

## 6. Web UI

- [ ] 6.1 Agent detail: updater version, state, reason, operations, floor, last observation.
- [ ] 6.2 Agents list: updater state column, filter and counts; Edge Ops banner while any agent is `bootstrap_required` or `unavailable`.
- [ ] 6.3 Remedy panel for `bootstrap_required` and `unavailable`: package-family command with target version, onboarding reinstall, and the Ansible automation link when available.
- [ ] 6.4 Release and add-on rollout views show updater outcome and name the host and reason for skipped targets.
- [ ] 6.5 Settings: kill switch and pause rule with their effective values.

## 7. Tests

- [ ] 7.1 Updater unit tests: valid install; add-on signature and manifest signature rejected as updater signatures; tampered binary; wrong kind; wrong platform; equal and lower versions; below floor; oversized input; symlinked input; environment key ignored.
- [ ] 7.2 Setuid integration tests as a non-root caller: destination, owner and mode are fixed; interrupted replacement before rename leaves the old updater working; stale temporary file is removed; floor heals.
- [ ] 7.3 Self-test failure prevents the rename.
- [ ] 7.4 Agent tests: state classification for each of the six states; replacement only on command; feature gating by operation.
- [ ] 7.5 Core tests: read model, settings defaults and overrides, cohort dispatch, pause by reason class, add-on eligibility transitions.
- [ ] 7.6 LiveView tests for the remedy panel, filters and rollout rows.
- [ ] 7.7 Enforcing-SELinux host verification of label preservation and of a privileged operation after replacement; record the result against the specific host and replacement time.

## 8. Rollout and documentation

- [ ] 8.1 Canary: one cohort, verified by the reported updater version of each host observed after dispatch, with an explicit failure branch for hosts that did not change.
- [ ] 8.2 Exercise the kill switch and the pause rule during the canary.
- [ ] 8.3 Update `docs/docs/agent-release-management.md`, `docs/docs/agent-platform-packages.md` and `docs/docs/native-addons.md`, including the amended "package-owned" statement and the bootstrap remedy.
- [ ] 8.4 Update the flag-contract comment in `go/pkg/agent/updaterflags/flags.go`.
- [ ] 8.5 Run `openspec validate add-agent-updater-self-update --strict`, the focused Go and Elixir checks, and the required Bazel suite; report every check not run.
