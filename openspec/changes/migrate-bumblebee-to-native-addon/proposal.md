# Change: Migrate Bumblebee exposure scanner to a native add-on

## Why

Bumblebee (`add-bumblebee-agent-exposure`, #3444) ships today as its own ad-hoc
`serviceradar-bumblebee-scan` deb/systemd package installed out-of-band. The native
add-on framework (#3425) now provides signed, discoverable, Edge-Ops-governed delivery
for optional agent capabilities.

Bumblebee's privileged full-system scan reads every local user's `$HOME` plus `/root`
(see `go/pkg/bumblebee/roots.go`), so it **cannot** run as an agent-launched go-plugin:
the deployed agent runs as the non-root `serviceradar` user with only `CAP_NET_RAW` and
no sudo (confirmed on the live `dusk01` agent, v1.2.83). The scanner must therefore keep
its root-owned systemd-timer execution model — but it should be *delivered, signed,
versioned, targeted, and drift-observed* as a native add-on instead of a standalone
package, so operators can turn it on per-cohort from Edge Ops after the initial RPM/deb
agent install rather than installing a second OS package out of band.

## What Changes

- Add `addons/bumblebee-scan/addon.yaml` (+ `config.schema.json`) declaring Bumblebee as a
  `native` add-on: `delivery: pushed-artifact` (primary; `os-package` fallback for
  air-gapped hosts), `supervision: systemd-timer`, the exposure-scan capability id,
  `requires` root-level filesystem read via the systemd-timer execution context, and
  `state_dirs` for the sanitized spool the agent ingests.
- Deliver and activate the **signed** Bumblebee artifact through the root-owned
  `agent-updater` (per `add-native-addon-delivery-models`): the privileged install path
  installs/enables the timer + service + spool-dir permissions and stages the scanner
  under the versioned `current`-symlink layout. The non-root agent never gains root.
- Gate the existing `BumblebeeSpoolService` ingest on the `AddonAssignment` (enabled /
  disabled / approved-capability subset) rather than the standalone `bumblebee_config`
  delivery path, and report per-add-on state and drift through the merged `AddonStatus`
  read model.
- Surface Bumblebee as a selectable feature-set / add-on in Edge Ops, reusing the merged
  `AddonPackage` / `AddonAssignment` resources and Edge Ops UI (no new control-plane
  schema).
- **BREAKING (packaging):** retire the standalone `build/packaging/bumblebee-scan` deb as
  the install/enable mechanism. The scanner binary, scanner config, systemd service, and
  timer ship inside the signed add-on bundle instead. The base `serviceradar-agent`
  package continues to not install the scanner.

## Impact

- **Affected specs:** `agent-configuration` — ADDED "Bumblebee Exposure Scanner Delivered
  As A Native Add-on" (supersedes the ad-hoc-deb "Optional native capability bundle
  installs scanner helper" delivery path described in `add-bumblebee-agent-exposure`; the
  scanner's *behavior* — root-owned, sanitized spool, partial-coverage reporting — is
  unchanged).
- **Affected code:** `addons/bumblebee-scan/`, `build/native_addons/` (inventory + bundle rule),
  `build/packaging/bumblebee-scan/` (retire standalone install), `go/pkg/agent/bumblebee_*`
  (gate ingest on the assignment), `go/pkg/agent/addon*` + `go/pkg/agent/addon_activation.go`
  (systemd-timer supervision + privileged install, delivered by delivery-models), and a
  control-plane Bumblebee `AddonPackage` seed/manifest import.
- **Depends on:** `add-native-addon-delivery-models` (systemd-timer supervision + privileged
  install + spool ingest), `add-native-addon-build-signing` (sign + publish the bundle),
  `add-agent-feature-sets` (manifest + assignment contract), `add-native-addon-edge-ops`
  (targeting + drift UI). Builds on `add-bumblebee-agent-exposure` (#3444).
- **Non-goal:** changing what Bumblebee scans, the exposure catalog pipeline, the risk
  reducer, or the device-detail UI — all delivered by #3444 and reused as-is.
