# Change: Native add-on delivery & supervision models

## Why
The framework (`add-agent-feature-sets`) defined five supervision models and three
delivery models, but the agent implements only `pushed-artifact` builds supervised as
`agent-sidecar` go-plugin subprocesses. The agent explicitly logs and skips any other
model. To deliver the full contract — and to migrate Bumblebee (`os-package` /
`systemd-timer`) and remote-access (`compiled-in` / `config-toggle`) onto it — the
agent needs to dispatch by delivery model, activate pushed-artifact tarballs with
verification and rollback, supervise the non-sidecar models, and keep a
last-known-good cache. The base agent package must also be carved so optional
capability binaries are not baked in.

## What Changes
- **Dispatch by delivery model** in the agent add-on manager: `config-toggle`,
  `pushed-artifact` (fetch + verify + activate), and `os-package` (activate an
  installed package), instead of only handling `agent-sidecar`.
- **Pushed-artifact activation**: reuse `release_runtime.go` staged-dir + `current`
  symlink + rollback; verify `sha256` + signature before activation; apply file
  capabilities per `requires.os_capabilities` via the root-owned `agent-updater`.
- **Wire the remaining supervision models**: `systemd-service`, `systemd-timer` (spool
  ingest), `ephemeral-helper`, and `config-toggle`.
- **Last-known-good cache + local override** for add-on assignments, mirroring the
  existing agent config override/cache pattern, so a delivery/verification failure
  falls back to the last good state rather than dropping the add-on.
- **Carve the base packaging boundary**: the base `serviceradar-agent` package SHALL
  contain only the core agent; define the signed `pushed-artifact` tarball format and
  the optional `os-package` add-on template (depends on `serviceradar-agent`, dormant
  on install).

## Impact
- **Depends on:** `add-agent-feature-sets` and `add-native-addon-build-signing`
  (verified artifacts + object storage to fetch from).
- **Affected specs:** ADDED requirements to `agent-configuration` (activation/rollback,
  non-sidecar supervision dispatch, last-known-good cache). The framework's high-level
  delivery/supervision requirements are implemented here, not redefined.
- **Affected code:** `go/pkg/agent/addon` manager dispatch; `release_runtime.go`
  staged-dir/symlink/rollback reuse; `go/cmd/agent-updater` capability application;
  systemd unit/timer + spool-ingest wiring; `build/packaging` base-agent carve +
  tarball/os-package templates.
