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
- [PowerDNS Telemetry](#powerdns-telemetry-add-on) covers `serviceradar-powerdns-addon`,
  including RPZ-hit DNS Activity events from PowerDNS Recursor protobuf logging.

## Documentation map

Native add-on documentation is split by job-to-be-done:

| Need | Page | Primary UI |
| --- | --- | --- |
| Understand package delivery, approval, assignment, status, rollback, and authoring | This page | **Settings > Agents > Add-ons** |
| Roll out NetFlow-to-process attribution and host flow evidence | [Host Network Visibility](./netprobe.md) | **Observability > Attributed Flows** |
| Add pod, namespace, image, Docker, and Compose context to host evidence | [Workload Identity](./workload-identity.md) | Agent detail, flow details, attributed flows |
| Ingest PowerDNS RPZ policy hits as OCSF DNS Activity events | [PowerDNS Telemetry](#powerdns-telemetry-add-on) | Universal event search / SRQL `in:events` |
| Roll the base `serviceradar-agent` binary | [Agent Release Management](./agent-release-management.md) | **Settings > Agents > Releases** |
| Configure NetFlow exporters and understand central flow ingest | [NetFlow Ingest Guide](./netflow.md) | **Observability > NetFlows** |

Keep these paths separate during operations. Agent releases update the base runtime;
native add-on packages update optional feature services that the base agent installs
and reports.

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
| `powerdns` | `serviceradar-powerdns-addon` | PowerDNS Recursor protobuf ingest and RPZ-to-OCSF DNS Activity mapping | DNS resolver hosts running ServiceRadar Agent |

Native add-ons are assigned from **Settings > Agents > Add-ons**, not from the base
agent release page. The base agent release catalog only rolls the `serviceradar-agent`
runtime. Add-on packages have their own package state, approval, version, artifact
digest, and target assignment lifecycle.

## PowerDNS telemetry add-on

The `powerdns` add-on is a Rust `agent-sidecar` that runs next to
`serviceradar-agent` on DNS resolver hosts. PowerDNS Recursor connects to the add-on's
localhost TCP listener and streams protobuf messages using PowerDNS' two-byte frame:
`[uint16 big-endian length][PBDNSMessage]`. The add-on decodes the vendored
PowerDNS `dnsmessage.proto`, defaults to RPZ/policy-hit filtering, maps accepted
records to OCSF 1.8.0 DNS Activity (`class_uid=4003`), and emits those events through
the generic `native-telemetry:v1` add-on stream.

The transport path is:

```text
PowerDNS Recursor -> serviceradar-powerdns-addon -> serviceradar-agent
  -> gateway StreamStatus source=addon:powerdns -> core-elx
  -> NATS pdns.ocsf -> db-event-writer -> ocsf_events
```

This path intentionally avoids exposing the cluster OTEL collector to DNS hosts. The
agent/gateway path already provides the authenticated agent identity, gateway,
partition, and source IP envelope; core-elx overwrites any add-on-supplied
`metadata.service_radar` values with that trusted envelope before publishing to NATS.

### PowerDNS Recursor config

For Recursor releases with Lua protobuf logging, configure a localhost receiver with
responses enabled and tagged-only output:

```lua
protobufServer("127.0.0.1:6000", { logResponses = true, taggedOnly = true })
```

For Recursor 5.1.0 and newer YAML configuration, use the equivalent
`logging.protobuf_servers` entry with `logResponses=true` and `taggedOnly=true`.
`taggedOnly=true` is the source-side volume control: RPZ policy/tagged answers are
sent, while the full query firehose is not. Keep the add-on's `rpz_only` config at
its default `true` unless full DNS query/response logging has been capacity-tested.

Use `setProtobufMasks()` when client-IP anonymization is required by the deployment.
`outgoingProtobufServer` is not needed for RPZ hit logging because the policy verdict
is present on the client-facing response stream.

### Event shape and SRQL

PowerDNS RPZ records are stored as OCSF DNS Activity events in `ocsf_events`. Search
them through the generic events entity:

```text
in:events class_uid:4003 time:last_24h sort:time:desc
in:events class_uid:4003 severity_id:3 time:last_1h
```

The add-on maps RPZ fields into first-class OCSF Security Control attributes:
`action_id`, `disposition_id`, and `firewall_rule`. PowerDNS source-only fields such
as server identity, device ID/name, message ID, newly observed domain, and requestor
ID are preserved under `unmapped`; unbounded raw protobuf payloads are not stored by
default.

If profiling shows CTI dashboards over DNS domains, client IPs, policy names, or
actions cannot be served from the generic JSONB event store at observed volume,
promote the v1 write model without changing the add-on contract: add generated and
indexed columns plus DNS continuous aggregates on `ocsf_events`, or create a
dedicated `ocsf_dns_activity` hypertable following the existing
`ocsf_network_activity` pattern. A dedicated `dns_events` SRQL entity should be added
with that promotion; until then, use `in:events class_uid:4003`.

## On-host layout

For pushed-artifact add-ons, the package-managed agent stages verified payloads under
the agent runtime root. The default layout is:

```text
/var/lib/serviceradar/agent/addons/
  netprobe/
    versions/0.2.18/
      serviceradar-netprobe
      serviceradar-netprobe.service
      netprobe_ebpf.o
    current -> versions/0.2.18
  workload-identity/
    versions/0.1.2/
      serviceradar-workload-identity
      serviceradar-workload-identity.service
      workload-identity.json
    current -> versions/0.1.2
```

The `current` symlink is the activation boundary. The agent verifies the artifact,
stages the versioned directory, applies required file capabilities through the
updater when declared by the manifest, flips `current`, installs the systemd unit,
and restarts the unit. Do not edit files in this tree by hand during normal
operations; manual edits are overwritten by the next reconciliation.

## Operator quick start

Use this path for a normal rollout:

1. Confirm the base agents are on a release new enough to install and report
   systemd-backed add-ons.
2. Import or sync the signed native add-on package from the release catalog.
3. Open **Settings > Agents > Add-ons** and verify the package is `verified`.
4. Review the manifest, required privileges, supported platforms, OCI digest, and
   granted capabilities.
5. Approve the package.
6. Assign the approved package to one canary agent or cohort before broad rollout.
7. Confirm add-on drift and health from the agent detail page.
8. Confirm host service state with `systemctl` for systemd-backed add-ons.
9. Validate the add-on's data surface, such as `in:addon_statuses`,
   `in:attributed_flows`, process listeners, or workload inventory.

The base **Agent Releases** page should show only base `serviceradar-agent` releases.
If add-on packages appear there, that is a catalog/UI bug: add-ons belong in the
add-on catalog so operators do not lose sight of base-agent runtime releases.

## Release readiness checklist

Before calling an add-on release ready, verify all of these:

- The add-on manifest version changed when the binary, schema, unit file, privileges,
  or runtime behavior changed.
- The package was built for every supported `os/arch` pair and includes its systemd
  unit, config schema, helper files, and eBPF object files when applicable.
- The release workflow produced signed artifacts, a signed discovery index, OCI
  digest metadata, and package verification status.
- The base agent release supports the add-on supervision model in the manifest.
- A canary assignment installs the package, flips the `current` symlink, restarts the
  unit, and reports fresh status.
- The agent detail page shows no assignment drift, stale status, unsupported
  architecture, or unhealthy observed service.
- The add-on's expected telemetry appears through SRQL and the relevant UI surface.

For `netprobe`, that means fresh `in:addon_statuses addon_id:netprobe` rows and
recent `in:attributed_flows` rows. For `workload-identity`, that means fresh
`in:addon_statuses addon_id:workload-identity` rows plus pod/container metadata in
flow details or workload inventory where runtime metadata is available.

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
sudo journalctl -u serviceradar-netprobe.service -n 100 --no-pager
sudo journalctl -u serviceradar-workload-identity.service -n 100 --no-pager
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

Every change to an add-on payload, config schema, manifest requirements, systemd unit,
or runtime behavior must bump that add-on's manifest version. The release build has a
native add-on version-bump gate so new binaries do not silently publish under an old
package version. Treat a failed gate as a release hygiene problem, not as a test to
skip.

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

## Fleet-scale targeting

Add-on targeting should be derived from control-plane inventory, settings, and cohort
selection. Do not maintain a static Helm value for every agent in a production fleet.
That pattern is acceptable only for short-lived demos and becomes unmanageable at
thousands of agents.

For large deployments:

- Use cohort assignment in **Settings > Agents > Add-ons** for broad rollout.
- Keep host capability and platform compatibility in the package manifest.
- Let the control plane compile desired add-on state into the agent config pushed
  through the gateway command/config path.
- Treat Helm values as deployment defaults and bootstrap configuration, not as the
  source of truth for per-agent add-on state.
- Track unsupported architectures, failed downloads, inactive services, and
  assignment drift in the add-on drift/status views.

## Status signals

Operators should expect three different states to reconcile:

| Signal | Source | Meaning |
| --- | --- | --- |
| Package state | Control plane package catalog | Whether the package is staged, approved, revoked, denied, and verified. |
| Desired assignment | Control plane agent config | Which add-on version and params an agent should run. |
| Observed status | Agent and host service | What is actually installed, active, unhealthy, or drifting on the host. |

When troubleshooting, avoid treating one signal as authoritative by itself. A package
can be approved but unassigned. An assignment can exist while an agent is offline. A
host service can be running an older package after a failed artifact download.

For systemd-backed add-ons, the host commands are still the fastest local truth:

```bash
sudo systemctl status serviceradar-agent.service --no-pager
sudo systemctl status serviceradar-netprobe.service --no-pager
sudo systemctl status serviceradar-workload-identity.service --no-pager
sudo systemctl status serviceradar.slice --no-pager
```

The ServiceRadar UI should surface the same drift in operator terms: assigned but not
installed, installed but inactive, unhealthy, unsupported architecture, unassigned
observed add-on, or stale status.

You can also inspect current add-on status through SRQL:

```text
in:addon_statuses sort:reported_at:desc limit:50
in:addon_statuses addon_id:netprobe state:unhealthy sort:reported_at:desc
in:addon_statuses addon_id:workload-identity active:true sort:reported_at:desc
```

For a host-side spot check, compare the running process path with the activated
version:

```bash
readlink -f /var/lib/serviceradar/agent/addons/netprobe/current
readlink -f /proc/$(pidof serviceradar-netprobe)/exe
readlink -f /var/lib/serviceradar/agent/addons/workload-identity/current
readlink -f /proc/$(pidof serviceradar-workload-identity)/exe
```

Those paths should point at the same versioned add-on directory. If the `current`
symlink changed but the running executable still points at an older version, the
systemd restart step failed or the host is running an older base agent that does not
fully reconcile systemd-backed add-ons.

## Rollback

Rollback add-ons through assignment state, not by hand-editing files under
`/var/lib/serviceradar/agent/addons`.

Preferred rollback order:

1. Disable the add-on assignment or retarget the previous approved package version in
   **Settings > Agents > Add-ons**.
2. Wait for the agent to receive the new compiled config and reconcile the unit.
3. Confirm observed status in the agent detail page and `in:addon_statuses`.
4. Verify the host unit state and running executable path with `systemctl` and
   `readlink`.

Manual host intervention should be reserved for break-glass recovery when the agent
control stream is offline or systemd cannot start the service. If manual recovery is
required, record the active version path before changing it so the control-plane
assignment can be corrected afterward.
