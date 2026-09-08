# Tasks: Native add-on delivery & supervision models

> Implements the agent-side delivery/supervision models beyond agent-sidecar from
> `add-agent-feature-sets`. Task numbers in parentheses map back to that change.

> **Complete.** The agent-side delivery + supervision is implemented end to end:
> pushed-artifact fetch → verify → (gzip-tarball-extract or bare binary) → stage →
> activate, explicit rollback, `agent-updater` file-capability application (setcap), and
> all supervision models (config-toggle, agent-sidecar, systemd-service/timer,
> ephemeral-helper), plus the LKG cache. The build side now produces the per-arch
> pushed-artifact tarball and an `os-package` add-on template ships under
> `build/packaging/addon-template/`. Base-agent packaging now contains only the
> core agent runtime; optional helpers such as netprobe and RDP adapter ship through
> native add-on artifacts.

## 0. Artifact reference plumbing (prerequisite)
- [x] 0.1 Carry the per-arch artifact reference to the agent: `AddonAssignmentConfig`
  gains `artifact_object_key` / `artifact_sha256` / `artifact_signature` /
  `target_os` / `target_arch` (proto + pb.go + pb.ex). (supports 3425 §5.2)
- [x] 0.2 Generator selects the artifact matching the agent's `metadata.os/arch` from
  `package.artifacts` and emits the reference; it joins the config version hash.

## 1. Packaging boundary
- [x] 1.1 Carve the base `serviceradar-agent` package to the core agent only (no
  optional capability binaries baked in via alternate targets). (3425 §3.1)
  — Done. **netprobe carved** (this is also migrate-netprobe §1.4): removed
  `//rust/netprobe` from the agent deb/rpm (`packages.bzl`) *and* both self-update
  release-runtime archives (`agent_release_runtime_files`,
  `agent_rdp_release_runtime_files` in `build/packaging/agent/BUILD.bazel`), dropped the
  `cap_net_raw,cap_bpf,cap_perfmon` `setcap` step + the `libpcap` recommends from the
  agent package — netprobe now ships as the `netprobe_addon_bundle` pushed-artifact
  (capabilities applied to the staged binary by the root-owned `agent-updater`). The
  `//rust/netprobe` build target is retained (now consumed by the add-on bundle).
  **RDP adapter carved:** the RDP-flavored managed-agent runtime target and release
  publisher path were removed; `serviceradar-rdp-adapter` now ships as the `rdp`
  `pushed-artifact` / `ephemeral-helper` native add-on, and remote-access resolves the
  staged helper path dynamically with the static config path as compatibility fallback.
- [x] 1.2 Define the signed `pushed-artifact` tarball format and the optional
  `os-package` add-on template (depends on `serviceradar-agent`, dormant on
  install). (§3.2)
  — Done within this change's scope (cryptographic signing/publishing is owned by
  `add-native-addon-build-signing`, secret-blocked on the Cosign + ed25519 keys).
  **Pushed-artifact tarball** — both agent-side extraction and build-side production:
  Agent `stageAddonArtifact` auto-detects a gzip tarball bundling the binary +
  manifest/config + systemd units and extracts it under `current/`
  (traversal/symlink/hardlink/bomb guarded; a bare binary still works). Build:
  `assemble_addon_bundle.py` gained `--tarball os/arch=out`, producing a deterministic
  (mtime=0, uid/gid=0, sorted, gzip mtime=0) gzip tarball per arch — binary 0755, the
  manifest/config + any `unit_entries` units 0644, all flattened to single-segment names
  matching `extractAddonTarball`; its name + sha256 are recorded per-arch in
  metadata.json. `defs.bzl` emits `{name}.{os}.{arch}.tar.gz` + an `all_tarballs`
  filegroup for bundles that set `pushed_artifact_tarball: True` (both samples do).
  Verified locally: layout/modes, byte-for-byte reproducibility across runs,
  metadata sha match, and backward-compat (no `--tarball` → unchanged output).
  **os-package template** — `build/packaging/addon-template/` codifies the os-package
  add-on contract (Depends `serviceradar-agent`; dormant install: units shipped but the
  postinst never enables them, the agent activates per supervision model; standard
  install paths; ships the self-describing `addon.yaml`). Inert scaffold (no
  `BUILD.bazel`/`PACKAGES` entry, so not built/released) with a copy-ready
  `packages.bzl` + `BUILD.bazel` snippet; `bumblebee-scan` is the shipping reference
  instance (os-package + systemd-timer).

## 2. Delivery dispatch
- [x] 2.1 Agent add-on manager dispatches an assignment to its delivery model:
  `config-toggle` / `pushed-artifact` fetch+verify+activate / `os-package`
  activate. (§6.1)
  — classifyAddonSupervision routes each supervision model explicitly:
  `agent_sidecar` stages (pushed_artifact) or runs the on-host binary (os_package) as
  a go-plugin; `config_toggle` is acknowledged as a compiled-in capability (no
  subprocess); `systemd_*`/`ephemeral_helper` are recognized but their supervision is
  not yet implemented (see 3.1/3.2); unknown models are reported unsupported. No model
  is silently mislabeled anymore.
- [x] 2.2 `pushed-artifact` activation: reuse `release_runtime.go` staged-dir +
  `current`-symlink + rollback; verify `sha256` + signature; apply file capabilities
  per `requires.os_capabilities` via the root-owned `agent-updater`. (§6.5)
  — Done. `addon_activation.go` does fetch + sha256 + ed25519 verify + versioned
  staging + atomic `current` symlink, plus explicit rollback primitives
  (`readAddonCurrentTarget` captures the prior version; `rollbackAddonCurrent` restores
  it or removes a failed first-time `current`, refusing a missing target). File
  capabilities now flow end to end: `os_capabilities` added to `AddonAssignmentConfig`
  (proto), emitted by `AgentConfigGenerator` from the manifest's `requires`, and applied
  by `agent-updater`'s `--addon-id/--addon-binary/--addon-capabilities` mode
  (`ApplyAddonCapabilities`: allowlist-bounded, safe-segment + symlink-escape guarded
  `setcap`). `applyAddonAssignments` captures the prior version, stages, applies
  capabilities, and on failure rolls back + keeps the last-known-good assignment.
  Verified: unit tests for normalize/resolve/escape/rollback; real `setcap` exec +
  allowlist + escape guards exercised on a Linux+root host.

## 3. Supervision models
- [x] 3.1 Wire `systemd-service` and `systemd-timer` (spool ingest). (§6.6)
  — Done. The agent discovers the `.service`/`.timer` units in the staged bundle and
  installs + enables the primary via the root-owned `agent-updater` (copy →
  daemon-reload → enable --now, with safe-segment + symlink-escape guards and self-clean
  on failure); reconciliation uninstalls units when an assignment is disabled/removed,
  and tracking is rehydrated from the staging root after a restart. Verified on a
  Linux+root host (service and timer: install → enabled/active → uninstall → removed).
  The timer's spooled output is ingested by the consuming add-on's own spool service
  (e.g. Bumblebee), not by this generic supervision path.
- [x] 3.2 Wire `ephemeral-helper` and `config-toggle`. (§6.6)
  — Done. `config_toggle` is acknowledged as a compiled-in capability (no subprocess).
  `ephemeral_helper` add-ons are staged + capability-granted and registered by resolved
  path (`EphemeralHelperPath`) for on-demand invocation by their consumer (e.g.
  remote-access spawns rdp-adapter per session); the agent does not run/supervise them.
  Reconciliation deregisters a helper when its assignment is disabled/removed.

## 4. Resilience
- [x] 4.1 Last-known-good cache + local override for add-on assignments (mirror the
  existing config override/cache pattern); fall back to last good on delivery or
  verification failure. (§6.7)
  — Last-known-good: the agent caches the last fully-verified spec per add-on
  (rememberAddonSpec) and, on a delivery/verification failure, reuses it verbatim
  (same binary, args, and config) instead of tearing down a running add-on or pairing
  an old binary with new config; with no cached spec the add-on was not running, so it
  is skipped until delivery succeeds. The cache is pruned to currently-assigned ids so
  a removed/re-added add-on cannot reuse a stale spec. (Reboot survivability while the
  store is down — persisting the spec to disk — is a follow-up.) Local override:
  `addons.local.json` in the agent config dir (applyLocalAddonOverrides) patches the
  fields it specifies onto the matching pushed assignment (others inherited) and
  appends local-only entries; a malformed file is ignored so it cannot break pushed
  delivery. Hardened per an adversarial review: path-segment validation on
  addon_id/version/binary-name blocks staging-path traversal.

## 5. Validation
- [x] 5.1 `openspec validate add-native-addon-delivery-models --strict` passes.
- [x] 5.2 Tests: activation rollback on bad signature; config-toggle enable/disable;
  cache fallback on fetch failure (plus supervision dispatch, tarball extraction, and
  capability application).
  — Done. Unit tests cover activation (sha256 / missing store / incomplete ref / ed25519
  valid+tampered), rollback (restore-prior / no-prior / missing-target / unsafe-id),
  capability normalize+allowlist / staged-binary resolution + escape, systemd unit
  discovery / primary-pick / reconcile decision / install validation, tarball extraction
  (binary+units, missing-binary, traversal/subdir/symlink, too-many-entries), supervision
  classification, LKG cache + prune, and the ephemeral-helper registry/reconcile; the
  generator artifact selection is covered in `agent_config_generator_test.exs`. Real
  `setcap` and `systemctl` install/enable/uninstall were exercised on a Linux+root host.
  The timer SPOOL-ingest test belongs to the consuming add-on (e.g. Bumblebee), not this
  change.
