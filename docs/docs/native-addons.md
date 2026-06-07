---
sidebar_position: 9
title: Native Add-ons
---

# Native Add-ons (Agent Feature Sets)

ServiceRadar agents gain optional capabilities through **native add-ons** - signed,
per-architecture binaries that operators select in Edge Ops and push down to chosen
agents. Add-ons are the native counterpart to [Wasm Plugins](./wasm-plugins.md): use
a Wasm plugin for a sandboxed checker, and a native add-on when a capability needs a
real OS process (a sidecar daemon, a scheduled scanner, a host-level collector).

This page is the operator and author overview for the add-on framework. Use it with
the first-party add-on runbooks:

- [Host Network Visibility](./netprobe.md) covers `serviceradar-netprobe`,
  including eBPF-backed process attribution and AF_XDP flow capture.
- [Workload Identity](./workload-identity.md) covers the standalone runtime
  metadata collector for Kubernetes, containerd, Docker, and Docker Compose hosts.

## Why native add-ons

The base `serviceradar-agent` package stays small and ships only the core agent.
Every optional capability is a separately built, signed add-on that stays dormant
until an operator selects it:

- **Selectable.** Operators choose which agents (or cohorts) run which add-ons in the
  Edge Ops UI - no rebuild, no redeploy of the base agent.
- **Signed.** Add-on artifacts are Cosign-signed (Rekor transparency log) and carry an
  ed25519 upload-signature; the agent verifies before activation.
- **Out-of-process by default.** The `agent-sidecar` model runs add-ons as
  [HashiCorp `go-plugin`](https://github.com/hashicorp/go-plugin) subprocesses
  (gRPC over a Unix-domain socket with AutoMTLS). The base agent never imports an
  add-on's code - isolation is CI-enforced - so an add-on crash cannot take down the
  agent.
- **Polyglot.** Add-ons can be written in Go or Rust; both speak the same gRPC
  contract to the agent's plugin client.

## Delivery and supervision models

An add-on declares two axes in its manifest. Together they tell the agent how to
obtain and run it:

**Delivery** - how the artifact reaches the host:

- `compiled-in` - capability already in the base agent; the assignment is just a
  config toggle (reserved for legacy/coupled capabilities such as remote-access).
- `pushed-artifact` - a signed per-arch tarball delivered over the existing
  runtime-push rail, staged and activated by the agent.
- `os-package` - a deb/rpm that depends on `serviceradar-agent` and is dormant until
  selected.

**Supervision** - how the capability runs on the host:

- `config-toggle` - flip a flag on an in-agent capability.
- `agent-sidecar` - supervised `go-plugin` subprocess (health checks, restart
  backoff, circuit breaker).
- `systemd-service` / `systemd-timer` - a long-running unit or a scheduled job that
  spools results for ingest.
- `ephemeral-helper` - a short-lived one-shot process.

The reference `sample` add-on is `pushed-artifact` / `agent-sidecar`.

Privileged host collectors should use the long-term systemd model. They run as
separate units under `serviceradar.slice`, optionally participate in a
`serviceradar-agent.target` or `PartOf=serviceradar-agent.service` lifecycle, and
report health/status through the agent. They are not child processes of the base
agent. This keeps privileges, restart policy, and cgroup accounting isolated while
still giving the UI one owner for desired-state drift.

## First-party add-ons

ServiceRadar currently ships these native add-ons:

| Add-on | Binary / unit | Primary capability | Typical target |
| --- | --- | --- | --- |
| `netprobe` | `serviceradar-netprobe.service` | Host network visibility and NetFlow-to-process attribution | Linux hosts and Kubernetes workers |
| `workload-identity` | `serviceradar-workload-identity.service` | Container, pod, namespace, image, and runtime metadata | Kubernetes workers, Docker hosts, and Docker Compose hosts |

Both add-ons are assigned from **Settings > Agents > Add-ons**, not from the base
agent release page. The base agent release catalog only rolls the `serviceradar-agent`
runtime. Add-on packages have their own package state, approval, version, artifact
digest, and target assignment lifecycle.

## Which add-on to deploy

Deploy add-ons independently. They complement each other, but neither one should be a
hard runtime dependency of the other:

| Need | Add-on | Notes |
| --- | --- | --- |
| Attribute NetFlow rows to local host processes | `netprobe` | Uses eBPF socket/process attribution and optional AF_XDP packet capture. |
| Show pod, namespace, container name, image, and Compose labels | `workload-identity` | Uses node-local CRI or Docker metadata. |
| Enrich attributed flows with workload context | Both | Core joins NetFlow, process attribution, and workload identity upstream. |
| Inventory containers without host flow capture | `workload-identity` only | Useful for asset inventory and future workload-level search. |
| Capture host flow evidence without container metadata | `netprobe` only | Useful on bare-metal or VM hosts where process context is sufficient. |

## Package format

Each add-on's manifest package lives under `addons/<id>/`:

- `addon.yaml` - the manifest (identity, delivery/supervision, capabilities,
  `requires`, `exec`, `config_schema` pointer). Mirrors `plugin.yaml`.
- `config.schema.json` - JSON Schema (draft 2020-12) for operator config; the control
  plane validates `AddonAssignment.params` against it before persisting.
- `BUILD.bazel`, `README.md`.

Implementation sources live elsewhere (`go/cmd/serviceradar-<id>-addon/` for Go,
`rust/` for Rust). See [`addons/sample-addon/README.md`](https://github.com/carverauto/serviceradar/blob/main/addons/sample-addon/README.md)
for the worked example.

## Capability and approval model

Like Wasm plugins, add-ons declare `capabilities` in the manifest, and an operator
approves a package before it can be assigned. On approval the operator may narrow the
granted set via `approved_capabilities`; the control plane sends that narrowed subset
(not the full manifest list) to the agent. Confirm the capabilities and the
delivery/supervision model during review, especially for add-ons that run as a
privileged sidecar or apply OS capabilities.

## Operator workflow in Edge Ops

Use **Settings > Agents > Add-ons** to review and target native add-ons:

1. Open a staged add-on package and review the manifest identity, declared
   capabilities, delivery and supervision model, supported artifacts, verification
   result, release tag, OCI reference, and digest.
2. Approve the package only after narrowing the granted capabilities to the minimum
   set needed. Denied or revoked packages are not assignable.
3. Target an approved add-on to a single agent or to a cohort. The cohort selector
   supports the current connected cohort and a custom list of agent IDs. The
   compatibility preview shows selected, compatible, unsupported, and unresolved
   targets before the assignment is created. Unsupported architectures are skipped.
4. Check the agent detail page after rollout. The **Add-on Drift** card reconciles
   assigned, installed, and active state, and calls out assigned-but-not-installed,
   assigned-but-not-active, unhealthy, unassigned observed add-ons, and architecture
   unsupported drift.

For systemd-backed host add-ons, also check the local host:

```bash
sudo systemctl status serviceradar-netprobe.service
sudo systemctl status serviceradar-workload-identity.service
sudo systemctl status serviceradar.slice
```

The expected ownership model is separate units under the ServiceRadar slice. Add-ons
should not run as privileged child processes of `serviceradar-agent`; the agent owns
desired state and status reporting, while systemd owns restart policy, hardening, and
cgroup accounting.

When creating an agent onboarding package in **Settings > Edge Ops > Onboarding**,
select an **Initial Feature Set** to preassign approved add-ons to the generated
agent identity. The new agent receives those add-on assignments when it enrolls and
fetches its first compiled configuration.

## Release and package workflow

Add-on packages are versioned independently from the base agent release. A ServiceRadar
release may include one base agent version and multiple native add-on package
versions. The expected release path is:

1. Update the add-on manifest under `addons/<id>/addon.yaml` and the implementation
   version in the source package.
2. Build signed per-platform add-on bundles through `build/native_addons/`.
3. Publish the add-on discovery index and artifact metadata with the release.
4. Import the package into ServiceRadar as `staged`.
5. Review and approve the package in **Settings > Agents > Add-ons**.
6. Assign the approved package to agents or cohorts.

Do not use **Settings > Agents > Releases** for add-on rollout decisions. That page is
for `serviceradar-agent` releases. Add-on packages belong in the add-on catalog so the
UI can keep base-agent upgrades, add-on approval, and add-on targeting separate.

## Runtime ownership model

The long-term host shape is one ServiceRadar slice with separate units:

```text
serviceradar.slice
  serviceradar-agent.service
  serviceradar-netprobe.service
  serviceradar-workload-identity.service
```

The base agent should not become a privileged process supervisor. It owns desired
state, artifact verification, configuration delivery, and reported status. Systemd
owns restart policy, hardening, privileges, and cgroup accounting for privileged
collectors.

For operators this means:

- `systemctl status serviceradar-agent.service` shows the base agent.
- `systemctl status serviceradar-netprobe.service` shows Host Network Visibility.
- `systemctl status serviceradar-workload-identity.service` shows Workload Identity.
- ServiceRadar UI reconciles assignment, installed state, active state, and drift.

## SDKs and authoring

The Go SDK (`go/pkg/addon`) wraps the `go-plugin` server boilerplate - handshake,
gRPC serving over the UDS, AutoMTLS, health, config decode from the typed assignment,
and result submission. The gRPC contract lives in `proto/agent/addon/v1/`. The Rust
SDK (`rust/addon-sdk`) provides the equivalent helper - go-plugin handshake, AutoMTLS,
and gRPC serving over the UDS - proven by the `rust-sample` reference add-on; the
documented contract in `proto/agent/addon/v1/` remains the source of truth for Rust
interop.

### Author checklist

Mirror the Wasm plugin author flow:

1. **Scaffold** `addons/<id>/` - copy `addons/sample-addon/` and edit `addon.yaml`
   (`id`, `version`, `delivery`, `supervision`, `language`, `capabilities`,
   `requires`, `exec`) and `config.schema.json`.
2. **Implement** the add-on service against the Go SDK (`go/pkg/addon`) or the Rust
   contract, using the gRPC service in `proto/agent/addon/v1/`. Put sources in
   `go/cmd/serviceradar-<id>-addon/` (or under `rust/`).
3. **Validate the manifest** against the add-on manifest schema and validate
   `config.schema.json` is a supported JSON-Schema subset.
4. **Enroll in the build** - add an entry to `build/native_addons/addon_inventory.bzl`
   so the release build cross-compiles, bundles, signs, and indexes your add-on per
   `(os, arch)` without bespoke release wiring.
5. **Verify locally** - build the binary and run the agent's add-on tests
   (`go test ./go/pkg/agent/addon/...`); confirm `addon.yaml` `requires` and
   `app_protocol_version` match the agent's plugin client.
6. **Publish & approve** - the signed bundle and discovery index ship with the
   release; import/approve the `AddonPackage` in Edge Ops, narrowing
   `approved_capabilities` as needed.
7. **Assign** - create an `AddonAssignment` for the target agent or cohort with
   validated `params`; the control plane compiles it into the agent config push and
   the agent supervises it.

## Lifecycle

1. Build a signed, per-arch bundle + discovery index (release workflow).
2. Import/approve the `AddonPackage` (`staged -> approved`) in the admin UI.
3. Assign to agents/cohort with config validated against `config.schema.json`.
4. The control plane pushes the typed add-on section in the versioned agent config.
5. The agent fetches/verifies/activates and supervises the add-on per its model.
6. Per-add-on `installed/active/unhealthy` status is reported back and reconciled
   against the desired assignment in the UI.
