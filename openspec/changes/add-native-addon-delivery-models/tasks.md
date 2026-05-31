# Tasks: Native add-on delivery & supervision models

> Implements the agent-side delivery/supervision models beyond agent-sidecar from
> `add-agent-feature-sets`. Task numbers in parentheses map back to that change.

> **In progress.** The `pushed_artifact` fetch → verify → stage → activate path is
> implemented end to end, now including explicit rollback and `agent-updater`
> file-capability application (setcap), plus the LKG cache. Remaining: the other
> delivery/supervision models (systemd-service/timer, ephemeral-helper) and the base
> packaging carve.

## 0. Artifact reference plumbing (prerequisite)
- [x] 0.1 Carry the per-arch artifact reference to the agent: `AddonAssignmentConfig`
  gains `artifact_object_key` / `artifact_sha256` / `artifact_signature` /
  `target_os` / `target_arch` (proto + pb.go + pb.ex). (supports 3425 §5.2)
- [x] 0.2 Generator selects the artifact matching the agent's `metadata.os/arch` from
  `package.artifacts` and emits the reference; it joins the config version hash.

## 1. Packaging boundary
- [ ] 1.1 Carve the base `serviceradar-agent` package to the core agent only (no
  optional capability binaries baked in via alternate targets). (3425 §3.1)
- [ ] 1.2 Define the signed `pushed-artifact` tarball format and the optional
  `os-package` add-on template (depends on `serviceradar-agent`, dormant on
  install). (§3.2)

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
- [ ] 3.1 Wire `systemd-service` and `systemd-timer` (spool ingest). (§6.6)
  — Status: not started — recognized by the dispatcher (logged as not-yet-implemented);
  installing units / ingesting the timer spool needs systemd + root to build and test.
- [ ] 3.2 Wire `ephemeral-helper` and `config-toggle`. (§6.6)
  — Status: partial — `config_toggle` is handled (acknowledged as a compiled-in
  capability, no subprocess launched); `ephemeral_helper` is recognized but the
  one-shot run is not yet implemented.

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
- [ ] 5.2 Tests: activation rollback on bad signature; timer spool ingest; config-toggle
  enable/disable; cache fallback on fetch failure.
  — Status: partial — activation tests cover sha256 mismatch, missing store, incomplete
  reference, and ed25519 verify (valid + tampered) in `addon_activation_test.go`; the
  generator emits + selects the per-arch artifact (covered in
  `agent_config_generator_test.exs`). Timer/config-toggle/cache tests pending their
  implementations.
