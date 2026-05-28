## Context
ServiceRadar already ships optional agent capabilities, but each one was wired by
hand:

- **Bumblebee** (issue #3444): a separate `serviceradar-bumblebee-scan` OS package
  that depends on `serviceradar-agent`, runs as a root-owned `systemd` oneshot +
  timer, writes a spool the non-root agent reads, and is enabled via a typed
  `BumblebeeConfig` proto field plus a local `enabled` toggle.
- **host-network-visibility / `netprobe`** (in flight): a Rust sidecar supervised
  by `go/pkg/agent/sidecar/manager.go` over a Unix-domain socket with health
  pings, restart backoff, and a circuit breaker — the capability that change calls
  `agent-sidecar-runtime`.
- **remote-access**: ~8k LOC compiled into the agent (`go/pkg/agent/remoteaccess`),
  multiplexed onto the agent's mTLS/SPIFFE gateway control stream, enabled by
  config flags; its Rust `rdp-adapter` is the only out-of-process piece and already
  rides the signed runtime-push rail as an ephemeral per-session helper.

Three capabilities, three packaging stories, three enablement mechanisms, and no
operator-facing way to choose what runs where. Meanwhile the **WASM plugin system**
already solved the adjacent problem well: a manifest (`plugin.yaml` +
`config.schema.json`), an in-repo inventory (`build/wasm_plugins/plugin_inventory.bzl`),
Bazel-built signed bundles, a Cosign + ed25519 signing pipeline keyed entirely from
the runtime secret store, a discovery index published as a release asset, a
verify-then-mirror importer, a staged→approved catalog (`PluginPackage`), per-agent
`PluginAssignment`, a schema-driven config form (`PluginConfigForm`), and delivery
through `AgentConfigGenerator` (`plugin_config` proto field 11).

This change generalizes that proven shape into a **native add-on framework** so that
adding a new optional agent capability is a declarative, signed, discoverable
operation — not a bespoke integration.

## Goals
- One contract an add-on author targets so their capability becomes a selectable,
  configurable option in Edge Ops with minimal boilerplate.
- A clean **base vs. add-on** boundary: base `serviceradar-agent` carries only the
  core agent; optional capabilities are separate signed artifacts, dormant until
  selected.
- **Operator-driven targeting**: the UI decides which agents/cohort an add-on is
  pushed to.
- A **delivery-agnostic catalog/UI layer**: the way an add-on's bits reach an agent
  (compiled-in toggle, pushed signed tarball, OS package) is an implementation
  detail behind the manifest; the catalog and UI never change when an add-on's
  delivery model changes.
- Reuse the WASM signing/discovery/verification rails rather than inventing a second
  trust system.
- Accurate **desired vs. observed** reconciliation: agents report what is installed,
  active, or degraded per add-on.

## Non-Goals
- Replacing the WASM plugin system. Add-ons cover native binaries/sidecars that are
  a poor fit for a WASM sandbox; WASM plugins remain the path for sandboxed,
  portable extensions.
- Extracting remote-access into a sidecar (see "Decision: remote-access stays
  compiled-in").
- Producing arm64 builds in this change. The manifest and contract are arch-aware so
  arm64 is additive later.
- Rewriting Bumblebee, netprobe, or remote-access. They are reference consumers and
  are migrated onto the contract in follow-up changes.
- Multitenancy / per-tenant routing. Add-on selection is infrastructure-level
  (per-agent / per-cohort), consistent with ServiceRadar's tenancy model; no
  `tenant_id` rows are introduced.

## Core concepts
- **Add-on**: the packaged optional capability — its manifest, signed per-arch
  artifacts (when applicable), delivery + supervision model, declared OS-capability
  needs, and config schema. The unit an author publishes.
- **Feature set**: the unit an operator selects and assigns. A feature set is either
  a single add-on or a curated, named bundle of add-ons (e.g. a "Security" set =
  Bumblebee + fingerprintd). Bundles are a thin grouping over add-ons; the add-on is
  the primitive.
- **Assignment**: a persisted decision that a feature set (with config) applies to a
  target (a specific agent, or a cohort of agents).

## The add-on manifest (`addon.yaml`)
Mirrors `plugin.yaml`; the author also ships a `config.schema.json` (JSON Schema,
reused verbatim by `PluginConfigForm` to render the config UI).

```yaml
id: bumblebee                      # stable kebab-case identifier
name: Bumblebee Exposure Scanner
version: 0.2.0                      # semver, independent of the agent version
description: Read-only developer-endpoint exposure scanner.
kind: native                       # discriminator vs. wasm
delivery: os-package               # compiled-in | pushed-artifact | os-package
supervision: systemd-timer         # config-toggle | agent-sidecar |
                                   #   systemd-service | systemd-timer |
                                   #   ephemeral-helper
capabilities: [bumblebee]          # capability strings the agent advertises when active
requires:
  base_agent: ">=1.2.0"            # base-agent version floor (compatibility gate)
  platforms: [linux]               # GOOS allow-list
  os_capabilities: []              # e.g. CAP_BPF, CAP_NET_RAW -> setcap + systemd hardening
  run_as: root                     # privilege envelope surfaced in the UI
artifacts:                         # required for pushed-artifact / os-package delivery
  - { os: linux, arch: amd64, object_key: "...", sha256: "...", signature_ref: "..." }
  - { os: linux, arch: arm64, object_key: "...", sha256: "...", signature_ref: "..." }
exec:
  binary: serviceradar-bumblebee-scan
  install_path: /usr/local/lib/serviceradar/bin
  systemd_units: [serviceradar-bumblebee-scan.service, serviceradar-bumblebee-scan.timer]
state_dirs:
  - { path: /var/lib/serviceradar/bumblebee, owner: root, mode: "0750" }
config_schema: config.schema.json
```

Authoring checklist (mirrors the WASM plugin author flow): create
`addons/<id>/` with `addon.yaml`, `config.schema.json`, sources/`BUILD.bazel`; add
one entry to `build/native_addons/addon_inventory.bzl`. Build, signing, indexing,
and release are then automatic.

## Delivery × supervision models
`delivery` answers "how do the bits get to the agent host"; `supervision` answers
"how does the agent run/lifecycle it". The agent-side add-on manager dispatches on
both, behind a single indirection so the catalog/UI never sees the difference.

| delivery        | what happens on enable                                                                 | typical supervision      |
|-----------------|----------------------------------------------------------------------------------------|--------------------------|
| `compiled-in`   | flip a config flag; the capability is already in the base agent binary                  | `config-toggle`          |
| `pushed-artifact` | fetch the signed per-arch tarball via the runtime-push rail (`release_runtime.go` + `agent-updater`), verify sha256 + signature, stage under a versioned dir, apply file capabilities per `requires.os_capabilities`, activate | `agent-sidecar`, `systemd-service`, `systemd-timer`, `ephemeral-helper` |
| `os-package`    | rely on a separately installed deb/rpm; enable then toggles config + activates the unit | `systemd-timer`, `systemd-service` |

Supervision models:
- **`config-toggle`** — compiled-in capability; enable/disable is purely config.
- **`agent-sidecar`** — long-lived child supervised by the generalized
  `go/pkg/agent/sidecar` manager over a per-add-on UDS (health ping, restart
  backoff, circuit breaker). This is the in-flight `agent-sidecar-runtime`
  capability, consumed here.
- **`systemd-service`** — long-lived OS-managed unit.
- **`systemd-timer`** — scheduled oneshot writing a spool the agent ingests
  (Bumblebee model).
- **`ephemeral-helper`** — spawned per session/job over stdio (RDP adapter model).

## Reference consumers (validate every model; migrated post-landing)
- **remote-access** → `delivery: compiled-in`, `supervision: config-toggle`
  (its `rdp-adapter` is `pushed-artifact` + `ephemeral-helper`). Validates
  compiled-in.
- **Bumblebee** → `delivery: os-package` (or `pushed-artifact`),
  `supervision: systemd-timer`. Validates the timer/spool model.
- **fingerprintd / netprobe** → `delivery: pushed-artifact`,
  `supervision: agent-sidecar`. Validates the UDS sidecar model.

## Signing & discovery (reuse the WASM rails)
- Build emits, per add-on, a deterministic bundle per `(os, arch)` plus a
  `metadata.json` and `sha256`, via a `build/native_addons/addon_inventory.bzl`
  inventory analogous to `plugin_inventory.bzl`.
- **Two signatures**, reusing the existing payload-agnostic tooling:
  Cosign/Sigstore over the OCI digest (`scripts/cosign_common.sh`) and an ed25519
  upload-signature (`build/wasm_plugins/upload_signature_tool.go`). Keys come only
  from the runtime secret store / env (`COSIGN_KEY_REF` e.g.
  `hashivault://cosign-native-addons`, `PLUGIN_UPLOAD_SIGNING_*`). **No private keys
  in source**; only public trust material is committed. A distinct signing-key id
  for native add-ons lets trust be scoped/revoked independently of WASM plugins.
- A `serviceradar-native-addon-index.json` is generated and published as a release
  asset, with per-arch digests. The importer reuses the verify-then-mirror pipeline
  (trusted-host allowlist, bounded fetch, digest + Cosign + upload-signature checks),
  then mirrors artifacts into ServiceRadar object storage. Import fails closed if
  trusted signing keys are not configured.

## Control-plane catalog & data model
- **`AddonPackage`** (Ash, `platform` schema) — parallel to `PluginPackage`: a
  staged→approved→revoked state machine with provenance (source OCI ref/digest,
  bundle digest, release tag), `kind: native`, per-arch artifact references,
  delivery/supervision metadata, declared capabilities and OS-capability/privilege
  requirements, and the config schema. A non-approved package is visible but not
  assignable.
- **`AddonAssignment`** (Ash) — parallel to `PluginAssignment`: ties an approved
  `AddonPackage` (or feature-set bundle) to a target (agent uid or cohort), with
  `enabled`, validated `params` (against `config.schema.json`), and any
  capability/privilege overrides recorded at approval time.
- **Decision — separate resources, shared plumbing.** Native add-ons get their own
  `AddonPackage`/`AddonAssignment` rather than overloading `PluginPackage` with a
  `kind` discriminator, because native fields (per-arch artifacts, supervision,
  privilege/OS-capabilities) would pollute the WASM-shaped schema and its
  state-machine semantics differ (a long-lived service restarts on upgrade vs. a
  reloaded WASM module). They **share** the importer/verification modules, the
  `PluginConfigForm` schema→form renderer, and the Edge Ops discovery panel.

## Delivery into agent config
- Assignments compile through `AgentConfigGenerator` into a dedicated typed add-on
  message in `AgentConfigResponse` (precedent: the typed `BumblebeeConfig` field).
  A single repeated `AddonAssignmentConfig` carries `addon_id`, version,
  delivery/supervision, per-arch `object_key`+`sha256`, `params_json`, and a
  header-based download token (tokens never embedded in URLs).
- The add-on section participates in the SHA256 `config_version` hash, so it gets
  `not_modified` semantics, cache invalidation, and both push (control-stream) and
  pull (poll) delivery for free.
- A catalog entry in the `DependencyCatalog` binds the `AddonAssignment` resource to
  `config_type: :addon`, an affected-agents resolver, and dispatch
  `:push_affected_agents`, so a UI change immediately recompiles and pushes effective
  config to exactly the targeted agents.

## Capability gating & reconciliation
- The agent advertises, per add-on, an installed/available/active/unhealthy state
  with a degradation reason (extending the existing `agent_capabilities`
  StatusResponse and `SidecarStatus`). For example, fingerprintd reports
  `unavailable` when CAP_BPF cannot be acquired.
- `AgentConfigResponse` only includes an add-on's config section when the feature set
  is enabled for that agent **and** the agent advertises (or, for
  `pushed-artifact`, can be delivered) the capability — so base-package agents never
  receive sections they cannot run.
- The UI reconciles operator-desired assignments against agent-observed state and
  surfaces drift (selected-but-unsupported, installed-but-unhealthy).

## Security & privilege
- All config/delivery is mTLS-only and agent-initiated; identity is cert-derived
  (tenant from issuer CA, component/partition from CN). Add-on artifacts add a
  second integrity layer (sha256 + Cosign + upload-signature) verified before
  activation, since a native binary runs with host privileges and has no WASM
  sandbox.
- The manifest's `requires.os_capabilities` and `run_as` drive both file
  capabilities (applied by the root-owned `agent-updater` at activation, not the
  non-root agent) and `systemd` hardening directives. The UI surfaces "this add-on
  needs elevated privileges" from the same declarations.
- File-capability provisioning at runtime (when a feature is toggled on after
  install, without a package reinstall) is performed by the existing root-owned
  updater helper; in containers, required capabilities remain pod-spec-time and the
  add-on reports `unavailable` if they were not granted.

## Decision: remote-access stays compiled-in
Extracting remote-access into a sidecar is out of scope. It is ~8k LOC of
in-process agent code plus ~4.7k LOC of glue, multiplexed onto the agent's single
mTLS/SPIFFE gateway control stream with per-frame HMAC bound to the agent's
`agentID`, and an in-process eBPF recorder — and it is ~99% complete and hardened.
The sidecar rail is UDS + health-check only (no SVID, no gateway channel), so
extraction would require minting a separate identity or proxying every frame
through the agent. Instead, remote-access is exposed as a `compiled-in` +
`config-toggle` feature set now; because the catalog/UI layer is delivery-agnostic,
a future extraction would not change the operator experience.

## Relationship to `agent-sidecar-runtime` and WASM
- The in-flight `agent-sidecar-runtime` (from `add-host-network-visibility-sidecar`)
  is the implementation of the `agent-sidecar` supervision model. This change
  defines the selection/catalog/lifecycle contract above it and does not duplicate
  or re-specify the UDS supervisor. The supervisor is generalized from a fixed
  boot-time sidecar list with wholesale start/stop to per-add-on dynamic
  registration with independent enable/disable.
- WASM plugins remain a separate, complementary system. The line: a WASM plugin is a
  sandboxed, portable module loaded into the agent's runtime; an add-on is a native
  binary/sidecar/timer that needs host execution, OS capabilities, or a language
  toolchain a WASM sandbox cannot host.

## Risks and mitigations
- **Two catalogs (WASM + add-on) drift in UX.** Mitigate by sharing the importer,
  config-form, and discovery LiveView components; only the resource schema differs.
- **Per-arch artifact matrix.** The index lists one entry per `(addon, version,
  arch)`; the agent advertises its arch so the generator selects the right blob.
  amd64-only initially; arm64 additive.
- **Runtime privilege provisioning.** File caps applied by the root-owned updater at
  activation; container deployments report `unavailable` rather than silently
  degrading.
- **Coordination churn with in-flight changes.** This change only defines the
  contract; Bumblebee/netprobe/remote-access conform in follow-ups owned by the
  maintainer, decoupled from this change's landing.
- **Long-lived service upgrade/rollback.** Reuse the staged-release/`current`
  symlink/rollback semantics; define restart-on-upgrade for `systemd-service` /
  `agent-sidecar` add-ons.

## Open questions
- Bundle vs. OS package as the canonical delivery for privileged add-ons: prefer
  signed `pushed-artifact` tarballs (uniform with WASM, runtime-toggleable) or keep
  deb/rpm for host-package-manager parity? The contract supports both; which is the
  default for new add-ons?
- Should feature-set bundles be first-class catalog resources or purely a UI-side
  grouping over add-ons in v1?
- Distinct `COSIGN_KEY_REF`/upload-signing key id for native add-ons (recommended)
  vs. reusing the WASM keys?
- Cohort targeting reuse: extend `AgentReleaseManager` cohorts/compatibility-preview,
  or a dedicated assignment-rollout path?
- Should compatibility gating hard-block selecting an add-on an agent can't run, or
  warn and record drift?
