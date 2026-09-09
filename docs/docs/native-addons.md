---
sidebar_position: 9
title: Native Add-ons
---

# Native Add-ons (Agent Feature Sets)

ServiceRadar agents gain optional capabilities through **native add-ons** - signed,
per-architecture binaries that operators select in Edge Ops and push down to chosen
agents. Add-ons are the native counterpart to [Wasm Plugins](./wasm-plugins.md): use
a Wasm plugin when the work fits the sandbox and host ABI, and use a native add-on
when a capability needs a real OS process (a sidecar daemon, a privileged
host-level collector, or another runtime that cannot fit inside Wasm).

This page is the operator and author overview for the add-on framework. Use it with
the first-party add-on runbooks:

- [Host Network Visibility](./netprobe.md) covers `serviceradar-netprobe`,
  including eBPF-backed process attribution and AF_XDP flow capture.
- [Workload Identity](./workload-identity.md) covers the standalone runtime
  metadata collector for Kubernetes, containerd, Docker, and Docker Compose hosts.
- [PowerDNS Telemetry](#powerdns-telemetry-add-on) covers `serviceradar-powerdns-addon`,
  including RPZ-hit DNS Activity events from PowerDNS Recursor protobuf logging.
- [Telemetry Display Contracts](./telemetry-display-contracts.md) covers the
  schema-driven log/event display contracts used by add-ons and plugins.

## Documentation map

Native add-on documentation is split by job-to-be-done:

| Need | Page | Primary UI |
| --- | --- | --- |
| Understand package delivery, approval, assignment, status, rollback, and authoring | This page | **Settings > Agents > Add-ons** |
| Roll out NetFlow-to-process attribution and host flow evidence | [Host Network Visibility](./netprobe.md) | **Observability > Attributed Flows** |
| Add pod, namespace, image, Docker, and Compose context to host evidence | [Workload Identity](./workload-identity.md) | Agent detail, flow details, attributed flows |
| Ingest PowerDNS RPZ policy hits as OCSF DNS Activity events | [PowerDNS Telemetry](#powerdns-telemetry-add-on) | Universal event search / SRQL `in:events` |
| Render add-on and plugin logs/events without producer-specific UI code | [Telemetry Display Contracts](./telemetry-display-contracts.md) | Event and log detail views |
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
- **Signed.** Add-on OCI bundles are Cosign-signed (Rekor transparency log), and
  each per-architecture pushed artifact carries an ed25519 signature from the agent
  release key; the agent verifies before activation.
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
| `netprobe` | `serviceradar-netprobe.service` | Host network visibility and NetFlow-to-process attribution. Policy is [Visibility Profiles](./visibility-profiles.md). | Linux hosts and Kubernetes worker-node agents |
| `workload-identity` | `serviceradar-workload-identity.service` | Container, pod, namespace, image, and runtime metadata | Kubernetes workers, Docker hosts, and Docker Compose hosts |
| `powerdns` | `serviceradar-powerdns-addon` | PowerDNS Recursor protobuf ingest and RPZ-to-OCSF DNS Activity mapping | DNS resolver hosts running ServiceRadar Agent |

Native add-ons are assigned from **Settings > Agents > Add-ons**, not from the base
agent release page. The base agent release catalog only rolls the `serviceradar-agent`
runtime. Add-on packages have their own package state, approval, version, artifact
digest, and target assignment lifecycle.

When first-party native add-on sync is enabled, ServiceRadar imports signed release
indexes using the shared [background catalog sync policy](./wasm-plugins.md#sync).
Verified first-party packages covered by deployment trust policy are approved
automatically. Helm is not an add-on catalog
allowlist, and importing or approving a package does not immediately change any
agent. Existing managed assignments and profiles track the newest approved compatible
package through a health-gated rollout. Explicit pins and non-first-party packages
remain manual.

This boundary is deliberate:

- **Import and approval** answer whether an immutable package digest is trusted and
  eligible for use.
- **Assignment policy** answers whether a source is pinned or tracks the latest
  approved package.
- **Rollout** delivers a candidate to canaries and bounded batches, then promotes
  the authoritative assignment only after fresh candidate-version health evidence.

### Kubernetes agent boundary

Do not run native add-on packages on the in-cluster `k8s-agent`. That agent exists
for Kubernetes integration work inside the demo or cluster deployment, where the pod
filesystem and security context are not suitable for host-level add-on activation,
systemd units, scanner state directories, or local sidecar process ownership.

Deploy host add-ons on agents installed on the hosts that own the capability:

- Run `netprobe` and `workload-identity` on Kubernetes worker-node agents, not on
  the in-cluster `k8s-agent` pod.
- Run Bumblebee exposure scanning on approved workstation, server, or developer
  endpoint agents that can own the scanner state directory and timer.
- Run `powerdns` on DNS resolver hosts where PowerDNS Recursor can connect to the
  add-on's localhost listener.

If the control plane compiles disabled host capability profiles or add-on
assignments for `k8s-agent`, the agent acknowledges and skips those local write and
activation paths. This prevents read-only pod filesystem failures from blocking the
agent's config-version update. Treat such skips as a targeting signal: move the
assignment to the host agent that should actually run the capability.

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
  -> NATS pdns.ocsf -> core-elx EventWriter -> ocsf_events
```

This path intentionally avoids exposing the cluster OTEL collector to DNS hosts. The
agent/gateway path already provides the authenticated agent identity, gateway,
partition, and source IP envelope; core-elx overwrites any add-on-supplied
`metadata.service_radar` values with that trusted envelope before publishing to NATS.

Native add-ons that produce scalar metrics use the same telemetry stream with the
ServiceRadar metric payload kind. The in-repo Go and Rust native add-on SDKs expose
helpers that wrap an encoded `serviceradar.metric.v1.MetricBatch`; the gateway
publishes that payload onto `metrics.*` without converting it through JSON. Raw OTLP
telemetry remains on the OTLP payload kinds.

### PowerDNS Recursor config

For Recursor releases with Lua protobuf logging, configure a localhost receiver with
response logging enabled:

```lua
protobufServer("127.0.0.1:6000", { logResponses = true, taggedOnly = false })
```

For Recursor 5.1.0 and newer YAML configuration, use the equivalent
`logging.protobuf_servers` entry with `logResponses=true` and `taggedOnly=false`.
Keep the add-on's `rpz_only` config at its default `true`; that is the source-side
volume control for ServiceRadar because the add-on drops non-policy responses before
emitting telemetry. Use `taggedOnly=true` only when the deployment owns and has
verified a separate Recursor tagging path, because RPZ verdicts are not guaranteed
to appear on the protobuf stream otherwise.

The add-on health check allows 60 seconds for Recursor to connect after startup or
reconfiguration, then reports `degraded` while no protobuf producer is connected.
Treat that diagnostic as configuration drift on the resolver: the ServiceRadar
assignment owns the receiver settings, but the deployment's PowerDNS configuration
management must durably own `logging.protobuf_servers` and restart or reload Recursor
when that setting changes.

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

Use this path for a normal first-party deployment:

1. Confirm the base agents are new enough to install and report the package's
   supervision model.
2. Assign the approved package to an agent or profile. Verified first-party packages
   default to **Track latest approved**; choose **Manual pin** only when the source
   must stay on that exact version.
3. Set the canary count, batch size, maximum parallel targets, soak time, and health
   timeout. Capability grants form a ceiling: a later package that asks for more
   privilege is blocked instead of silently expanding access.
4. Publish future signed ServiceRadar releases normally. Catalog sync imports and
   approves trusted first-party packages, and managed sources create rollouts without
   per-agent clicks.
5. Watch **Add-on Fleet** only when a rollout pauses or a row is classified as
   **Action required**. Healthy, updating, unavailable, expected-inactive, and
   observed-only rows are separate states and are not all treated as failures.
6. For a systemd-backed add-on, use `systemctl` only when the fleet evidence calls
   for host-level diagnosis.

For a third-party package, approval and the initial version selection remain
explicit. Approval makes a signed digest eligible; it does not opt a source into
automatic updates. An operator can subsequently enable **Track latest approved**
for that source. Automatic candidates remain bound to the same package origin and
capability ceiling.

The base **Agent Releases** page should show only base `serviceradar-agent` releases.
If add-on packages appear there, that is a catalog/UI bug: add-ons belong in the
add-on catalog so operators do not lose sight of base-agent runtime releases.

## Release readiness checklist

Before calling an add-on release ready, verify all of these:

- The add-on manifest version changed when the binary, schema, unit file, privileges,
  or runtime behavior changed.
- The package was built for every supported `os/arch` pair and includes its systemd
  unit, config schema, helper files, and eBPF object files when applicable.
- The release workflow produced signed artifacts, a published discovery index, OCI
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
| Detect short-term sysmon or SNMP metric spikes on the host that collects them | `anomaly` | Consumes local `metric-feed:v1`; default assignment params subscribe to `sysmon` and `snmp` only. |
| Attribute NetFlow rows to local host processes | `netprobe` | Uses eBPF socket/process attribution and optional AF_XDP packet capture. |
| Show pod, namespace, container name, image, and Compose labels | `workload-identity` | Uses node-local CRI or Docker metadata. |
| Enrich attributed flows with workload context | Both | Core joins NetFlow, process attribution, and workload identity upstream. |
| Inventory containers without host flow capture | `workload-identity` only | Useful for asset inventory and future workload-level search. |
| Capture host flow evidence without container metadata | `netprobe` only | Useful on bare-metal or VM hosts where process context is sufficient. |

## Reference consumer coordination

The native add-on framework intentionally landed before every historical optional
capability was fully migrated. Keep these boundaries in mind when planning or
reviewing follow-up changes:

| Capability | Current add-on contract | Coordination notes |
| --- | --- | --- |
| Edge anomaly detection | `pushed-artifact` with `agent-sidecar` supervision and `metric-feed:v1` input | Assign only to agents that collect sysmon or SNMP. The add-on defaults to `metric_feed.sources=["sysmon","snmp"]`; ICMP/timeseries feeds are opt-in. Capacity shed is reported as OCSF Event Log Activity with `status_code=anomaly_capacity_shed`, not as an anomaly verdict. |
| Bumblebee exposure scanning | `pushed-artifact` or `os-package` with `systemd-timer` supervision | Keep the timer and spool model. The scanner should remain root-owned and dormant until assigned; the non-root agent should ingest bounded spool output only when an approved `AddonAssignment` enables the package. |
| Host Network Visibility / netprobe | `pushed-artifact` with `systemd-service` supervision | Keep netprobe out of the base agent package. Its manifest declares Linux platform support, required file capabilities, systemd unit metadata, and eBPF/runtime files. The agent should activate the staged artifact, apply capabilities through the updater, install the unit, and report drift through `addon_statuses`. |
| Remote access | `compiled-in` with `config-toggle`; RDP adapter is the separate `rdp` `pushed-artifact` / `ephemeral-helper` add-on | Remote access stays compiled in because the control-stream, HMAC, and session-recorder paths remain tightly coupled to the base agent. The per-session RDP helper ships through the native add-on pipeline, keeping the base-agent package boundary explicit. |

These migration notes are coordination guardrails, not permission to bypass the
framework. New native capabilities should default to out-of-process add-ons unless
they are tightly coupled to the base agent like current remote-access.

## Package format

Each add-on's manifest package lives under `addons/<id>/`:

- `addon.yaml` - the manifest (identity, delivery/supervision, capabilities,
  `requires`, `exec`, `config_schema` pointer). Mirrors `plugin.yaml`.
- `config.schema.json` - JSON Schema (draft 2020-12) for operator config; the control
  plane validates `AddonAssignment.params` against it before persisting.
- `signal_schemas` entries in `addon.yaml` - required when the add-on emits logs or
  events. Each entry references a payload JSON Schema and a display contract JSON file
  stored in the package bundle. See
  [Telemetry Display Contracts](./telemetry-display-contracts.md).
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
   result, release tag, OCI reference, digest, and any `signal_schemas` display
   contracts for emitted logs or events.
2. Approve the package only after narrowing the granted capabilities to the minimum
   set needed. Denied or revoked packages are not assignable.
3. Target an approved add-on to a single agent or to a cohort. The cohort selector
   supports the current connected cohort and a custom list of agent IDs. The
   compatibility preview shows selected, compatible, unsupported, and unresolved
   targets before the assignment is created. Unsupported architectures are skipped.
   Do not target in-cluster `k8s-agent` identities for host-level native add-ons.
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
3. Include payload schemas and display contracts for every emitted log or event in
   the bundle and list them in `signal_schemas`.
4. Publish the add-on discovery index and artifact metadata with the release.
5. Sync the package into ServiceRadar. A verified package covered by first-party
   trust policy is approved automatically; other packages remain staged for review.
6. Assign the approved package to agents or profiles and select **Track latest
   approved** or **Manual pin**. First-party assignments default to tracking.
7. For a tracking source, let the rollout coordinator canary, health-gate, batch,
   and promote newer approved packages. Approval alone never rewrites the stable
   package selection.

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

Native add-ons that produce advisory feeds, scan diagnostics, or other scheduled
datasets should declare package-owned `producer_schedules` in `addon.yaml` instead
of requiring core code changes. The Go SDK exposes `ProducerScheduleContract`,
`NewProducerScheduleContract`, and the `CapabilityProducerScheduleV1` constants so
authors can construct the same manifest shape used by Wasm plugins. ServiceRadar
persists the contract, renders schedule settings from it, stores operator cadence
and credential choices, and records status against the generic schedule state.

Wasm producers dispatch through `plugin.run_action`. Native add-on producers
dispatch through `addon.run_command`. Both paths use the same control-plane
schedule state and the same edge boundary: core/web-ng sends the command over
agent commandbus to agent-gateway, agent-gateway forwards it to the selected
agent, and the agent invokes the local add-on over the add-on gRPC protocol.
Add-ons remain responsible for provider-specific download, validation, and
normalization, and they never receive direct access to web-ng, core-elx, or NATS
JetStream object storage.

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

1. The release workflow builds a signed, per-architecture bundle and discovery
   index.
2. Catalog sync imports the immutable digest and applies package trust policy.
3. An assignment or profile selects **Manual pin** or **Track latest approved**.
4. A newer eligible package creates a persisted rollout. The stable package remains
   authoritative while per-target candidate overrides advance through canary and
   bounded batches.
5. The agent fetches, verifies, activates, supervises, and reports the exact candidate
   version.
6. Fresh post-advance evidence must pass the configured health gate and soak. Success
   promotes the source; failure removes the candidate override, restores the prior
   desired state, pauses the rollout, and blocks immediate retriggering.

## Fleet-scale targeting

Add-on targeting should be derived from control-plane inventory, settings, and cohort
selection. Do not maintain a static Helm value for every agent in a production fleet.
That pattern is acceptable only for short-lived demos and becomes unmanageable at
thousands of agents.

For large deployments:

- Use cohort assignment in **Settings > Agents > Add-ons** for broad rollout.
- Keep host capability and platform compatibility in the package manifest.
- For the `anomaly` add-on, start with the default broad profile only when most
  matched agents collect sysmon or SNMP. Otherwise narrow the SRQL target to the
  metric-owning host agents and keep `metric_feed.sources` to `sysmon` and `snmp`
  unless ICMP/timeseries anomaly detection is intentionally enabled.
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

The ServiceRadar UI classifies each effective row into exactly one operator state:

| Category | Meaning |
| --- | --- |
| Healthy / running | Fresh evidence matches the stable desired package. |
| Updating | An active rollout is converging and remains inside its health window. |
| Action required | Fresh evidence proves a runtime failure, desired state is invalid/incompatible, or a rollout paused/failed. |
| Unavailable / stale | The agent is offline or evidence is too old to prove current health. |
| Expected inactive | A disabled config toggle or dormant ephemeral helper is behaving as designed. |
| Observed only | No assignment owns the reported built-in or historical runtime. Healthy observed-only rows are informational. |

Every non-healthy row includes a stable reason code and evidence age. Offline or
stale evidence is never mislabeled as a current runtime failure.

In **Add-on Fleet > Automatic rollouts**, use **Show finished** to reveal history
when active rollouts are present. When none are active, history appears automatically.
Use **Previous** and **Next** beneath the table to browse finished rollouts; active
rollouts remain visible on every page. **Review rollout** opens the page containing
the linked rollout and expands its details. Pagination covers the recent rollouts
loaded by the view, not the complete historical archive.

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

## Pause, pin, and rollback

Operate add-ons through assignment and rollout state, not by hand-editing files under
`/var/lib/serviceradar/agent/addons`.

- **Pause** stops new batches while preserving already-converged targets for
  diagnosis. **Resume** continues from persisted rollout state.
- **Cancel** removes candidate overrides that have not become authoritative and
  leaves the stable source unchanged.
- **Rollback** removes candidate overrides first, restores prior desired package and
  parameters, and waits for fresh recovery evidence before more targets advance.
- **Manual pin** opts a source out of future automatic candidates. Pinning is the
  normal way to hold a known version; it should not require deleting assignments.

After recovery, confirm observed status in **Add-on Fleet** or `in:addon_statuses`.
Use `systemctl` and `readlink` only when reported evidence indicates a host service or
activation failure.

Manual host intervention should be reserved for break-glass recovery when the agent
control stream is offline or systemd cannot start the service. If manual recovery is
required, record the active version path before changing it so the control-plane
assignment can be corrected afterward.
