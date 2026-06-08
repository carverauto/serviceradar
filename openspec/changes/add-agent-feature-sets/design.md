## Context
ServiceRadar already ships optional agent capabilities, but each one was wired by
hand:

- **Bumblebee** (issue #3444): a separate `serviceradar-bumblebee-scan` OS package
  that depends on `serviceradar-agent`, runs as a root-owned `systemd` oneshot +
  timer, writes a spool the non-root agent reads, and is enabled via a typed
  `BumblebeeConfig` proto field plus a local `enabled` toggle.
- **host-network-visibility / `netprobe`** (in flight): a Rust sidecar originally
  supervised by a fixed-list agent sidecar manager over a Unix-domain socket. The
  native add-on contract moves optional runtime ownership out of the base agent:
  `agent-sidecar` add-ons use go-plugin, while netprobe is now a
  `systemd-service` add-on with an attach-only status/config loop.
- **remote-access**: ~8k LOC compiled into the agent (`go/pkg/agent/remoteaccess`),
  multiplexed onto the agent's mTLS/SPIFFE gateway control stream, enabled by
  config flags; its Rust `rdp-adapter` is the only out-of-process piece and already
  rides the signed runtime-push rail as an ephemeral per-session helper.

Three capabilities, three packaging stories, three enablement mechanisms, and no
operator-facing way to choose what runs where. The **WASM plugin system** already
solved the adjacent problem well — manifest + `config.schema.json`, in-repo
inventory, Bazel-built signed bundles, a Cosign + ed25519 signing pipeline keyed
from the runtime secret store, a discovery index published as a release asset, a
verify-then-mirror importer, a staged→approved catalog (`PluginPackage`), per-agent
`PluginAssignment`, a schema-driven config form (`PluginConfigForm`), and delivery
through `AgentConfigGenerator` (`plugin_config` proto field 11).

This change generalizes that proven shape into a **native add-on framework** for the
capabilities that are a poor fit for a WASM sandbox (native binaries, sidecars,
privileged or polyglot components). Two further inputs shaped the design:

- **Datadog's Agent binary-size work** (referenced in issue #3425). Their bloat came
  from transitively pulling a feature's *entire dependency tree* into a binary even
  when the feature is off; their fixes are build tags and package isolation. For us,
  this makes "compiled-in, toggled at runtime" the worst case for size, and makes
  **out-of-process plugins** the right default — they keep the base agent's
  dependency set (and size) from growing as capabilities are added.
- **HashiCorp `go-plugin`** as the chosen runtime substrate for the out-of-process
  model: a mature (MPL-2.0), widely deployed (Terraform, Vault, Nomad, Boundary)
  subprocess-over-gRPC plugin framework whose gRPC mode supports **polyglot plugins**
  (Go and Rust alike).

## Goals
- One contract an add-on author targets so their capability becomes a selectable,
  configurable option in Edge Ops with minimal boilerplate.
- A clean **base vs. add-on** boundary: base `serviceradar-agent` carries only the
  core agent; optional capabilities are separate signed artifacts, dormant until
  selected.
- **Keep the base agent small.** Adding an add-on MUST NOT grow the base agent's
  dependency set or binary size.
- **Operator-driven targeting**: the UI decides which agents/cohort an add-on is
  pushed to.
- A **delivery-agnostic catalog/UI layer**: how an add-on's bits reach an agent and
  how it is supervised are implementation details behind the manifest; the catalog
  and UI never change when an add-on's delivery model changes.
- Reuse the WASM signing/discovery/verification rails rather than inventing a second
  trust system.
- Accurate **desired vs. observed** reconciliation: agents report what is installed,
  active, or degraded per add-on.

## Non-Goals
- Replacing the WASM plugin system. WASM plugins remain the path for sandboxed,
  portable extensions; add-ons cover native/polyglot/privileged capabilities.
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
  Bumblebee + netprobe). Bundles are a thin grouping over add-ons; the add-on is
  the primitive.
- **Assignment**: a persisted decision that a feature set (with config) applies to a
  target (a specific agent, or a cohort of agents).

## The add-on manifest (`addon.yaml`)
Mirrors `plugin.yaml`; the author also ships a `config.schema.json` (JSON Schema,
reused verbatim by `PluginConfigForm` to render the config UI).

```yaml
id: netprobe                       # stable kebab-case identifier
name: Host Network Visibility
version: 0.1.0                     # semver, independent of the agent version
description: Passive p0f/JA4 host fingerprinting + DPI sidecar.
# NOTE: illustrative — shown as agent-sidecar to exercise the `plugin:` block. The
# real netprobe migration uses supervision: systemd-service (capability-granted via
# setcap), since it needs CAP_BPF/CAP_PERFMON and speaks a bespoke IPC, not the add-on
# gRPC contract; see migrate-netprobe-to-native-addon.
kind: native                       # discriminator vs. wasm
delivery: pushed-artifact          # compiled-in | pushed-artifact | os-package
supervision: agent-sidecar         # config-toggle | agent-sidecar (go-plugin) |
                                   #   systemd-service | systemd-timer |
                                   #   ephemeral-helper
language: rust                     # go | rust (informs SDK/handshake helper)
capabilities: [fingerprint]        # capability strings the agent advertises when active
requires:
  base_agent: ">=1.2.0"            # base-agent version floor (compatibility gate)
  platforms: [linux]               # GOOS allow-list
  os_capabilities: [CAP_BPF, CAP_NET_RAW]  # -> setcap + systemd/sandbox hardening
  run_as: serviceradar             # privilege envelope surfaced in the UI
plugin:                            # for supervision: agent-sidecar
  protocol: grpc                   # go-plugin gRPC protocol
  app_protocol_version: 1          # go-plugin app protocol version (compat negotiation)
  services: [Fingerprint]          # gRPC services the plugin serves
artifacts:                         # required for pushed-artifact / os-package delivery
  - { os: linux, arch: amd64, object_key: "...", sha256: "...", signature_ref: "..." }
  - { os: linux, arch: arm64, object_key: "...", sha256: "...", signature_ref: "..." }
exec:
  binary: serviceradar-netprobe
  install_path: /usr/local/lib/serviceradar/bin
state_dirs:
  - { path: /var/lib/serviceradar/netprobe, owner: serviceradar, mode: "0750" }
config_schema: config.schema.json
```

Authoring checklist (mirrors the WASM plugin author flow): create `addons/<id>/`
with `addon.yaml`, `config.schema.json`, sources/`BUILD.bazel`; add one entry to
`build/native_addons/addon_inventory.bzl`. Build, signing, indexing, and release are
then automatic.

## Delivery × supervision models
`delivery` answers "how do the bits get to the agent host"; `supervision` answers
"how does the agent run/lifecycle it". The agent-side add-on manager dispatches on
both, behind a single indirection so the catalog/UI never sees the difference.

| delivery        | what happens on enable                                                                 | typical supervision      |
|-----------------|----------------------------------------------------------------------------------------|--------------------------|
| `compiled-in`   | flip a config flag; the capability is already in the base agent binary (legacy/coupled only) | `config-toggle`     |
| `pushed-artifact` | fetch the signed per-arch tarball via the runtime-push rail (`release_runtime.go` + `agent-updater`), verify sha256 + signature, stage under a versioned dir, apply file capabilities per `requires.os_capabilities`, activate | `agent-sidecar`, `systemd-service`, `systemd-timer`, `ephemeral-helper` |
| `os-package`    | rely on a separately installed deb/rpm; enable then toggles config + activates the unit | `systemd-timer`, `systemd-service` |

Supervision models:
- **`config-toggle`** — compiled-in capability; enable/disable is purely config.
- **`agent-sidecar`** — a separate plugin **subprocess** managed via HashiCorp
  `go-plugin`: the agent (go-plugin *client*) launches the add-on binary, performs
  the handshake, and speaks **gRPC** over a local transport. Lifecycle, health,
  graceful shutdown, and restart are handled by the generalized
  `go/pkg/agent/sidecar` manager wrapping go-plugin clients (one per add-on), with
  restart backoff and a circuit breaker layered on top. This is the in-flight
  `agent-sidecar-runtime` capability, refactored onto go-plugin and consumed here.
- **`systemd-service`** — long-lived OS-managed unit.
- **`systemd-timer`** — scheduled oneshot writing a spool the agent ingests
  (Bumblebee model).
- **`ephemeral-helper`** — spawned per session/job over stdio (RDP adapter model).

### Decision: out-of-process plugins are the default
New native capabilities SHOULD ship as **out-of-process plugins** (`pushed-artifact`
or `os-package` delivery, `agent-sidecar` supervision), not compiled into the base
agent. Rationale (Datadog): a separate plugin binary is its own compilation unit, so
the base agent **never imports the add-on's Go packages** and its dependency set and
size do not grow as capabilities are added — while still being runtime-selectable.
`compiled-in` is reserved for capabilities too coupled to the agent to extract
(today: remote-access). Signed `pushed-artifact` tarballs are the **default** delivery
for new add-ons; `os-package` (deb/rpm) is a secondary option for hosts that prefer
package-manager parity.

## Out-of-process plugins via HashiCorp go-plugin
The `agent-sidecar` model is implemented with `github.com/hashicorp/go-plugin`:

- **Subprocess + gRPC.** The agent launches each add-on as a child process; they
  communicate over gRPC. go-plugin handles the handshake (magic-cookie guard against
  accidental exec), protocol/version negotiation (`VersionedPlugins` /
  `app_protocol_version`), graceful shutdown, plugin stdout/stderr capture, and
  managed cleanup of orphaned plugin processes.
- **Local transport with mutual TLS.** Plugins listen on a **Unix-domain socket**
  under a restricted directory (not loopback TCP), and host↔plugin gRPC uses
  go-plugin **AutoMTLS** (ephemeral per-launch certificates). This gives a private,
  authenticated channel without minting a SPIFFE identity for each add-on.
- **Polyglot.** gRPC plugins can be written in any language that implements the
  go-plugin handshake and serves the gRPC contract. Go add-ons use go-plugin's server
  helper directly; **Rust add-ons** (e.g. the `rust-sample` reference) implement the
  go-plugin handshake line and serve the same gRPC service on the Unix socket. The agent never
  cares which language a plugin is written in.
- **Bidirectional services.** go-plugin's broker lets a plugin call back into the
  agent (host services), giving native add-ons the same "host capability" ergonomics
  WASM plugins have (`submit_result`, `get_config`, `log`) — a unified host-services
  contract across both systems.
- **Not the stdlib `plugin` package.** HashiCorp go-plugin does NOT use Go's
  `-buildmode=plugin`/`.so` loading; it does not import the stdlib `plugin` package
  and therefore does not disable method dead-code elimination (see Build hygiene).
  Crash isolation, independent versioning, and runtime reload all come for free
  because each plugin is its own process.

## Binary size & dependency hygiene (lessons from Datadog)
First-class because ServiceRadar agents run on edge/size-sensitive hosts:

- **Dependency isolation (the core guardrail).** The base agent SHALL reference
  add-ons only through the go-plugin client / gRPC interface and SHALL NOT import any
  add-on's implementation package. CI enforces this with `go list`/`goda`: the base
  agent's transitive package set must not grow when an add-on is added.
- **Method dead-code elimination.** The agent and Go add-on binaries are built with
  method DCE enabled, with a `whydeadcode` check in CI so a dependency cannot
  silently re-disable it (Datadog's ~20% win).
- **No stdlib `plugin`.** Importing Go's stdlib `plugin` package is forbidden in
  agent/add-on builds — it forces dynamic linking and disables DCE (Datadog's 245 MiB
  containerd lesson). go-plugin is used instead.
- **Size budget.** Per-artifact binary sizes are tracked across releases (e.g. via
  `go-size-analyzer`) with a regression gate, since size is an edge requirement.
- **Single agent build artifact (no build flavors).** We do NOT split the agent into
  lean/full build-tag flavors — maintaining multiple agent build packages is not worth
  the cost. remote-access stays compiled-in and config-toggled (unchanged). Lean-edge
  is achieved instead by the out-of-process-plugin default + dependency isolation
  above: because new capabilities are separate plugin binaries the base agent never
  imports, a single agent artifact stays small as the product grows.

## Reference consumers (validate every model; migrated post-landing)
- **remote-access** → `delivery: compiled-in`, `supervision: config-toggle`
  (its `rdp-adapter` is `pushed-artifact` + `ephemeral-helper`). Validates
  compiled-in.
- **Bumblebee** → `delivery: os-package` (or `pushed-artifact`),
  `supervision: systemd-timer`. Validates the timer/spool model.
- **rust-sample** → `delivery: pushed-artifact`, `supervision: agent-sidecar`
  (go-plugin gRPC, Rust plugin). Validates the out-of-process plugin model.
- **netprobe** → `delivery: pushed-artifact`, `supervision: systemd-service`
  (capability-granted via `setcap`; bespoke IPC, not the add-on gRPC contract).
  The real host-visibility migration; see `migrate-netprobe-to-native-addon`.

## Signing & discovery (reuse the WASM rails)
- Build emits, per add-on, a deterministic bundle per `(os, arch)` plus a
  `metadata.json` and `sha256`, via a `build/native_addons/addon_inventory.bzl`
  inventory analogous to `plugin_inventory.bzl`.
- **Two signatures**, reusing the existing payload-agnostic tooling **and the existing
  signing keys**: Cosign/Sigstore over the OCI digest (`scripts/cosign_common.sh`) and
  an ed25519 upload-signature (`build/wasm_plugins/upload_signature_tool.go`). Native
  add-ons reuse the same `COSIGN_KEY_REF` and upload-signing key already used for WASM
  plugins (no new key). Keys come only from the runtime secret store / env; **no
  private keys in source**, only public trust material is committed.
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
  privilege/OS-capabilities) would pollute the WASM-shaped schema and the
  state-machine semantics differ (a long-lived plugin process restarts on upgrade vs.
  a reloaded WASM module). They **share** the importer/verification modules, the
  `PluginConfigForm` schema→form renderer, and the Edge Ops discovery panel.
- **Decision — feature-set bundles are a v1 UI grouping, not a resource.** The add-on
  is the primitive. For v1, a "feature set" is an Edge Ops multi-select: an operator
  picks one or more add-ons and applies them to targets, and each is recorded as an
  individual `AddonAssignment`. There is no saved, named `FeatureSet` resource yet; a
  first-class, reusable/curated bundle resource is deferred until there is demand and
  can be added later without changing the add-on/assignment core.

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
  StatusResponse and `SidecarStatus`). For example, netprobe reports
  `unavailable` when CAP_BPF cannot be acquired.
- `AgentConfigResponse` only includes an add-on's config section when the feature set
  is enabled for that agent **and** the agent advertises (or, for `pushed-artifact`,
  can be delivered) the capability — so base-package agents never receive sections
  they cannot run.
- The UI reconciles operator-desired assignments against agent-observed state and
  surfaces drift (selected-but-unsupported, installed-but-unhealthy).

## Security & privilege
- All config/delivery is mTLS-only and agent-initiated; identity is cert-derived
  (tenant from issuer CA, component/partition from CN). Add-on artifacts add a second
  integrity layer (sha256 + Cosign + upload-signature) verified before activation,
  since a native binary runs with host privileges and has no WASM sandbox.
- Host↔plugin traffic uses a restricted Unix socket plus go-plugin AutoMTLS, so the
  agent↔add-on channel is private and authenticated without per-add-on SPIFFE
  identities.
- The manifest's `requires.os_capabilities` and `run_as` drive both file
  capabilities (applied by the root-owned `agent-updater` at activation, not the
  non-root agent) and process hardening. The UI surfaces "this add-on needs elevated
  privileges" from the same declarations.
- File-capability provisioning at runtime (when a feature is toggled on after install,
  without a package reinstall) is performed by the root-owned updater helper; in
  containers, required capabilities remain pod-spec-time and the add-on reports
  `unavailable` if they were not granted.

## Decision: remote-access stays compiled-in
Extracting remote-access into a sidecar is out of scope. It is ~8k LOC of in-process
agent code plus ~4.7k LOC of glue, multiplexed onto the agent's single mTLS/SPIFFE
gateway control stream with per-frame HMAC bound to the agent's `agentID`, and an
in-process eBPF recorder — and it is ~99% complete and hardened. Instead it is exposed
as a `compiled-in` + `config-toggle` feature set now — its current behavior is
unchanged, and operators turn it on/off by configuration. Because the catalog/UI
layer is delivery-agnostic, a future extraction would not change the operator
experience.

## Relationship to `agent-sidecar-runtime` and WASM
- The in-flight `agent-sidecar-runtime` (from `add-host-network-visibility-sidecar`)
  is refactored to become the go-plugin-backed implementation of the `agent-sidecar`
  supervision model. This change defines the selection/catalog/lifecycle contract
  above it; `go/pkg/agent/addon` manages one go-plugin client per assigned add-on
  with dynamic registration and independent enable/disable. The old fixed-list
  sidecar launcher has been removed; netprobe's non-go-plugin IPC is scoped to
  `go/pkg/agent/netprobe.AttachManager`, which only attaches to the externally
  supervised `systemd-service` add-on.
- WASM plugins remain a separate, complementary system. The line: a WASM plugin is a
  sandboxed, portable module loaded into the agent's runtime; an add-on is a native
  binary/sidecar/timer that needs host execution, OS capabilities, or a language
  toolchain a WASM sandbox cannot host.

## Native add-on SDK
A first-party SDK lowers the authoring bar, parallel to the WASM `serviceradar-sdk-go`:

- **Go SDK** — wraps go-plugin's server boilerplate (handshake, gRPC serving over the
  Unix socket, AutoMTLS, health, config decode from the typed assignment, result
  submission via host services) so a Go add-on is a manifest plus a service
  implementation.
- **Rust helper** — a documented handshake + gRPC-contract crate (or guidance) so
  Rust add-ons like the `rust-sample` reference interoperate with the agent's go-plugin
  client identically.

## Rejected alternatives
- **Go stdlib `plugin` (`-buildmode=plugin` / `.so`).** Rejected: importing it
  disables method dead-code elimination and forces dynamic linking (Datadog's 245 MiB
  lesson); same-process so a plugin crash kills the agent; requires the exact same Go
  toolchain and dependency versions as the host; no reload; Linux/macOS only; Go-only
  (no Rust). It contradicts both the size and the isolation/polyglot goals.
- **Hand-rolled gRPC-over-UDS without a framework.** Considered. Workable and
  framework-free, but go-plugin already provides handshake, version negotiation,
  AutoMTLS, managed cleanup, and bidirectional host services that we would otherwise
  reimplement. We adopt go-plugin and keep the gRPC service contract explicit so Rust
  plugins remain first-class.
- **Build-tag agent flavors (lean vs. full).** Considered for binary size, rejected:
  maintaining multiple agent build packages is not worth the cost. The
  out-of-process-plugin default + dependency isolation keep the single base agent from
  growing, addressing the size goal without flavor proliferation. remote-access stays
  compiled-in and config-toggled.

## Risks and mitigations
- **New dependency (`hashicorp/go-plugin`, MPL-2.0).** Accepted: ServiceRadar is
  Apache-2.0, and MPL-2.0 is file-level (weak) copyleft, so consuming go-plugin
  unmodified only requires preserving its license/notices and imposes no obligation
  on ServiceRadar's own source.
- **Rust plugin interop.** Rust add-ons must implement the go-plugin handshake;
  mitigate with the SDK's documented contract + a reference Rust plugin.
- **Two catalogs (WASM + add-on) drift in UX.** Mitigate by sharing the importer,
  config-form, and discovery LiveView components; only the resource schema differs.
- **Per-arch artifact matrix.** The index lists one entry per `(addon, version,
  arch)`; the agent advertises its arch so the generator selects the right blob.
  amd64-only initially; arm64 additive.
- **Runtime privilege provisioning.** File caps applied by the root-owned updater at
  activation; container deployments report `unavailable` rather than silently
  degrading.
- **Coordination churn with in-flight changes.** This change defines the contract;
  Bumblebee/netprobe/remote-access conform in follow-ups owned by the maintainer.

## Resolved decisions
- **Default delivery:** signed `pushed-artifact` tarballs; `os-package` (deb/rpm) is a
  secondary option.
- **Signing:** reuse the existing WASM signing key + infra (no native-addon-specific
  key).
- **Feature-set bundles:** v1 UI multi-select grouping over add-ons; no first-class
  bundle resource yet.

## Open questions
- Cohort targeting reuse: extend `AgentReleaseManager` cohorts/compatibility-preview,
  or a dedicated assignment-rollout path?
- Should compatibility gating hard-block selecting an add-on an agent can't run, or
  warn and record drift?
