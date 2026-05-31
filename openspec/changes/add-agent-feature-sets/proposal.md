# Change: Add agent feature sets (selectable native add-on framework)

## Why
ServiceRadar agents gain optional capabilities — the Bumblebee exposure scanner,
a planned Rust `netprobe` host-visibility sidecar, the
remote-access suite — through ad-hoc, per-feature plumbing. Each new capability
reinvents its own packaging, enablement toggle, config proto field, and delivery
path, and there is no operator-facing way to choose which capabilities an agent
runs. The Bumblebee change already references an "Edge Ops feature-set
deployment" and an "optional native capability bundle" that do not yet exist.

Issue #3425 asks for a base `serviceradar-agent` package plus add-on capabilities
that operators select in the web-ng Edge Ops UI and push down to chosen agents.
Not everything is a good fit for the WASM plugin system, so this is a
complementary mechanism for native binaries/sidecars. This change defines the
missing foundation: a single, signed, discoverable **agent add-on framework**,
modeled on the existing WASM plugin developer experience, that any author can
target so their capability becomes a selectable option in Edge Ops.

This change designs and ratifies the contract. Existing native capabilities are
named as its reference consumers and are migrated onto it in follow-up work, not
rewritten here.

## What Changes
- Define a first-class **agent add-on framework**: a declarative add-on manifest
  (`addon.yaml` + `config.schema.json`), an in-repo registry, signed
  per-architecture artifacts, a control-plane catalog, operator selection and
  targeting in Edge Ops, downward delivery, agent-side supervision, and status
  reporting.
- Establish the **base/add-on packaging boundary**: the base `serviceradar-agent`
  package SHALL contain only the core agent; every optional capability ships as a
  separately built, signed add-on artifact and stays dormant until selected.
- Support three **delivery models** — `compiled-in` (config toggle on a capability
  already in the base agent; reserved for legacy/coupled capabilities), `pushed-artifact`
  (signed per-arch tarball delivered over the existing runtime-push rail), and
  `os-package` (deb/rpm) — and the matching **supervision models** — `config-toggle`,
  `agent-sidecar`, `systemd-service`, `systemd-timer`, and `ephemeral-helper`.
- Default new native capabilities to **out-of-process plugins** so the base agent
  stays small: the `agent-sidecar` model is implemented with **HashiCorp `go-plugin`**
  (subprocess + gRPC, polyglot — Go and Rust), and the base agent SHALL reference
  add-ons only through the plugin interface, never importing an add-on's packages
  (CI-enforced dependency isolation). The Go stdlib `plugin` package is explicitly
  rejected.
- Apply **binary-size hygiene** (Datadog Agent lessons): enable method dead-code
  elimination with a `whydeadcode` guard, forbid the stdlib `plugin` import, and gate
  per-artifact size regressions.
- Provide a first-party **native add-on SDK** (Go server helper over go-plugin +
  documented Rust handshake/contract) so authoring an add-on is a manifest plus a
  service implementation.
- Reuse the WASM plugin **signing and discovery rails** verbatim where possible
  (Cosign over the OCI digest + an ed25519 upload-signature, signing keys sourced
  from the runtime secret store / environment with **no keys committed to source**,
  a discovery index published as a release asset, and a verify-then-mirror
  importer).
- Add a **control-plane catalog** (`AddonPackage` staged→approved state machine +
  per-agent/cohort `AddonAssignment`) and compile assignments into the existing
  versioned agent-config push pipeline so a selection deterministically reaches the
  targeted agents.
- Add an **Edge Ops UI** to browse available add-ons, configure them from their
  `config.schema.json`, and choose which agents/cohort receive them (reusing the
  agent-release cohort + compatibility-preview pattern).
- Report **per-add-on installed/available/active/unhealthy state** (with
  degradation reasons) back to the control plane and surface it per agent so the UI
  reconciles desired vs. observed.

## Impact
- **Affected specs:** NEW `agent-feature-sets`, NEW `native-addon-builds`;
  ADDED requirements to `agent-config`, `agent-configuration`, `build-web-ui`,
  `agent-registry`.
- **Affected code (subsequent implementation):** `build/native_addons/` inventory
  + Bazel rules; reuse of `scripts/cosign_common.sh` and the upload-signature
  tooling; an add-on assignment message + a gRPC add-on service contract in
  `proto/`; a new `hashicorp/go-plugin` dependency and a native add-on SDK
  (Go server helper + Rust handshake contract); `elixir/serviceradar_core` Ash
  resources (`AddonPackage`/`AddonAssignment`) and `AgentConfigGenerator`; the
  web-ng importer, Edge Ops LiveView, and reuse of `PluginConfigForm`; a
  `go/pkg/agent` add-on manager plus the generalized `go/pkg/agent/sidecar` manager
  wrapping go-plugin clients; `go/cmd/agent-updater` artifact activation with
  file-capability application; and CI dependency-isolation + size + dead-code-elimination
  gates.
- **Coordination:** generalizes and refactors the in-flight `agent-sidecar-runtime`
  capability (from `add-host-network-visibility-sidecar`) onto `go-plugin` as the
  `agent-sidecar` supervision model, and supersedes Bumblebee's ad-hoc "native
  capability bundle" language. Bumblebee, host-network-visibility/netprobe, and
  remote-access are the reference consumers and are conformed to this contract in
  follow-up changes.
- **New external dependency:** `github.com/hashicorp/go-plugin` (MPL-2.0) — accepted;
  compatible with ServiceRadar's Apache-2.0 (MPL is weak/file-level copyleft, consumed
  unmodified, so it only requires preserving go-plugin's notices).
- **Complementary to** the WASM `wasm-plugin-system`: this framework covers
  non-WASM native capabilities and does not replace WASM plugins.
- Out of scope: producing arm64 toolchain builds (the manifest and contract are
  arch-aware so arm64 can be added later without contract changes), and extracting
  remote-access out of the agent binary (left compiled-in; see design).
