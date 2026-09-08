# Change: Scalable one-touch netprobe attribution + manifest-driven add-on seeding

## Why

Flow→process attribution is the goal of the netprobe add-on, but the current
operator experience does not scale to 10–10,000 agents, and shipped code changes
never reach operators:

- **Capture-centric config doesn't scale.** The assignment form is built around
  `capture_interfaces` / DPI / per-device bindings — per-agent settings that an
  operator cannot reasonably enumerate across a large fleet (every host may have a
  different NIC). Yet **attribution needs none of them**: the eBPF kprobes are
  kernel-wide, so the flow→process source works with zero interface config. The UI
  conflates the optional passive-capture feature with attribution and makes the
  capture fields look required.
- **The agent gated attribution on capture.** `netprobeConfigHasWork` required
  `capture_interfaces > 0 && device_bindings > 0`, so enabling netprobe for
  attribution-only (empty capture) did nothing.
- **The add-on package is frozen, decoupled from the manifest.**
  `NetprobeAddonPackageSeeder` takes its version + signed artifact refs from
  external runtime config and a hardcoded `@version "0.1.0"`, and is a no-op when
  artifacts are not configured. So the package operators see in the UI stayed at
  `0.1.0` with a stale `config_schema` no matter how much netprobe code, the
  manifest version, or the schema changed. `native-addons.yml` also only ran on
  manual dispatch, so the artifacts were never refreshed on release.
- **The attribution inventory still has a polling hot path.** The ring reader can
  be event-driven, but the process snapshot path still periodically scans
  `/proc/net/{tcp,tcp6,udp,udp6}` and `/proc/*/fd` to rebuild listener ownership.
  That does not scale on busy Kubernetes workers and keeps attribution above the
  fleet CPU budget even when packet capture is disabled.

## What Changes

- **One-touch attribution:** enabling the netprobe add-on runs the eBPF
  process-attribution path on its own, with no capture interfaces or device
  bindings required. A single fleet-wide assignment (Enable) is valid for any
  number of agents.
- **Control-plane host visibility assignment:** host-network visibility
  enablement is stored in the database/settings UI and delivered as effective
  agent config through agent-gateway commandbus/control-stream pushes. Local
  network/process observations travel agent-up, are persisted by core, and are
  correlated with independently ingested NetFlow/IPFIX in CNPG. Per-agent
  `host_slices` in Helm and a NetFlow down-to-agent replay loop are not required.
- **Capture/DPI demoted to advanced opt-in:** `capture_interfaces`, `dpi`,
  `default_sample_interval_ms`, `external_flow_match_window_ms`, and
  `device_bindings` become optional advanced fields, collapsed in the operator
  form, never required for an attribution rollout.
- **Manifest-driven add-on package seeding:** the seeded `AddonPackage` version,
  `config_schema`, and capability/requirement metadata track the in-image
  `addons/netprobe/addon.yaml` + `config.schema.json`, instead of a hardcoded
  version. Signed artifact refs continue to come from the published bundle, but a
  manifest version bump (or schema change) is reflected on the next core boot.
- **Republish on release:** `native-addons.yml` triggers on `v*` tags so the
  published add-on artifacts (and the UI version) track each release.
- **Event-driven attribution inventory:** netprobe replaces periodic host-wide
  procfs listener/process discovery with eBPF socket/process lifecycle events and
  bounded user-space caches. Process command line and container identity remain
  required forensic enrichment fields; procfs is retained only as a temporary,
  bounded cold-path enrichment implementation until eBPF exec/cgroup metadata
  capture replaces it, not as recurring global discovery or PID attribution.
- **Protocol-aware correlation:** attribution matching handles TCP, UDP, ICMP,
  ICMPv6, node-SNAT, and pod-local cases with protocol-specific tuple rules
  instead of treating every flow as a TCP-style 5-tuple.
- **Bounded delivery path:** ring buffers, local IPC queues, agent queues, and
  gateway batches expose drop counters/lag and use bounded backpressure or
  coalescing so burst handling is observable and cannot grow without limit.
- **Performance release gate:** attribution-only netprobe must remain below the
  sustained fleet CPU budget on representative busy workers, without persistent
  drops, queue lag, attribution freshness regressions, or protocol hit-rate
  regressions, before the release path is considered complete.

## Impact

- Affected specs: `host-network-visibility` (attribution-only config, advanced
  capture), `agent-feature-sets` (manifest-driven add-on package seeding).
- Affected code:
  - `go/pkg/agent/push_loop_config.go` — `netprobeConfigHasWork` (done in v1.2.90).
  - `addons/netprobe/config.schema.json` — defaults + advanced grouping.
  - `elixir/serviceradar_core/lib/serviceradar/plugins/netprobe_addon_package_seeder.ex` — manifest-driven version/schema.
  - `elixir/web-ng/...` add-on assignment config form — collapse advanced fields, attribution-only default.
  - `.forgejo/workflows/native-addons.yml` — `v*` tag trigger (done in v1.2.90).
  - `rust/netprobe/ebpf/src/lib.rs`, `rust/netprobe/src/attribution.rs` — event-driven listener/process inventory, cache-backed snapshots, CPU gate.
  - `elixir/serviceradar_core/...` agent config compiler / `AgentCommandBus` — DB/settings-driven visibility config and commandbus push.
  - `elixir/serviceradar_core/lib/serviceradar/flow_attribution.ex` — persist
    agent-up observations and perform protocol-aware OCSF correlation.
  - `go/pkg/agent/netprobe/*`, `go/pkg/agent/push_loop_flow_attribution.go` — bounded event queues, drain sizing, and delivery counters.
