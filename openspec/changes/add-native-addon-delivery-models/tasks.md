# Tasks: Native add-on delivery & supervision models

> Implements the agent-side delivery/supervision models beyond agent-sidecar from
> `add-agent-feature-sets`. Task numbers in parentheses map back to that change.

> **In progress** (branch `feat/native-addon-delivery-models`). The `pushed_artifact`
> fetch → verify → stage → activate path is implemented end to end (agent + generator
> artifact reference). Remaining: rollback + `agent-updater` capability application,
> the other delivery/supervision models, the LKG cache, and the packaging carve.

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
- [ ] 2.1 Agent add-on manager dispatches an assignment to its delivery model:
  `config-toggle` / `pushed-artifact` fetch+verify+activate / `os-package`
  activate. (§6.1)
  — Status: partial — `pushed_artifact` is dispatched (fetch+verify+activate); the
  `config-toggle` and `os-package` branches still fall through to `binary_path`.
- [ ] 2.2 `pushed-artifact` activation: reuse `release_runtime.go` staged-dir +
  `current`-symlink + rollback; verify `sha256` + signature; apply file capabilities
  per `requires.os_capabilities` via the root-owned `agent-updater`. (§6.5)
  — Status: partial — `go/pkg/agent/addon_activation.go` does object-store fetch,
  sha256 + ed25519 verify, versioned staging, and atomic `current` symlink (reusing
  hashutil + the release ed25519 trust root). Remaining: explicit rollback of a prior
  version and file-capability application via `agent-updater`.

## 3. Supervision models
- [ ] 3.1 Wire `systemd-service` and `systemd-timer` (spool ingest). (§6.6)
- [ ] 3.2 Wire `ephemeral-helper` and `config-toggle`. (§6.6)

## 4. Resilience
- [ ] 4.1 Last-known-good cache + local override for add-on assignments (mirror the
  existing config override/cache pattern); fall back to last good on delivery or
  verification failure. (§6.7)
  — Status: partial — the versioned staging dir doubles as the last-known-good cache:
  on a delivery/verification failure the agent reuses the existing `current` staged
  binary (lastKnownGoodAddonBinary) instead of tearing down a running add-on, so a
  transient object-store/signature failure is non-fatal and a reboot can relaunch from
  the last-good binary while the store is unavailable. Remaining: a local override file
  (mirroring the agent config override).

## 5. Validation
- [x] 5.1 `openspec validate add-native-addon-delivery-models --strict` passes.
- [ ] 5.2 Tests: activation rollback on bad signature; timer spool ingest; config-toggle
  enable/disable; cache fallback on fetch failure.
  — Status: partial — activation tests cover sha256 mismatch, missing store, incomplete
  reference, and ed25519 verify (valid + tampered) in `addon_activation_test.go`; the
  generator emits + selects the per-arch artifact (covered in
  `agent_config_generator_test.exs`). Timer/config-toggle/cache tests pending their
  implementations.
