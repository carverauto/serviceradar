## Context

netprobe is a native add-on delivering eBPF process attribution (flow→PID) plus an
optional passive packet-capture/DPI feature. Attribution is the high-value,
fleet-wide capability; capture/DPI is a targeted, interface-specific feature.

Today the two are entangled at three layers:
1. **Agent** — `applyVisibilityConfigLaunched` only started netprobe when
   `netprobeConfigHasWork` was true, and that required capture interfaces + device
   bindings. (Fixed in v1.2.90: it now starts on `enabled` alone.)
2. **Config schema / UI** — the operator form renders every property of the
   add-on's `config_schema`, capture fields included and unmarked, so a fleet
   rollout appears to demand per-agent NIC lists.
3. **Seeding** — `NetprobeAddonPackageSeeder` builds the `AddonPackage` from a
   hardcoded `@version "0.1.0"` and runtime-config artifact refs, no-ops without
   artifacts, and never re-derives version/schema from the in-image manifest. The
   demo package was therefore frozen at `0.1.0` with a stale schema.
4. **Inventory performance** — the attribution ring can be event-driven, but the
   listener/process inventory snapshot still periodically reconstructs host state
   from `/proc/net/*` plus `/proc/*/fd`. That is a generated kernel view, not an
   event stream, and polling it is too expensive for always-on fleet attribution.

## Goals / Non-Goals

- Goals: a single fleet-wide "Enable" produces attribution on any number of agents
  with zero interface config; published add-on version + schema reach operators on
  release; capture/DPI remain available but optional/advanced; attribution-only
  netprobe stays below 1% sustained process CPU on representative busy workers;
  flow correlation covers TCP, UDP, ICMP, ICMPv6, pod-local, and node-SNAT cases;
  delivery queues expose lag/drop counters and stay bounded under burst traffic.
- Non-Goals: auto-selecting capture interfaces for the capture/DPI feature (a
  separate follow-up); changing the attribution correlation pipeline; per-tenant
  add-on catalogs; using inotify/fanotify or tighter procfs polling as the primary
  listener/process lifecycle source.

## Decisions

- **Attribution is capture-independent.** netprobe's kprobes attach kernel-wide
  regardless of `capture_interfaces`; `enabled` alone is sufficient "work" to run
  and keep netprobe up. Capture/DPI engage only when interfaces/bindings are set.
- **Host-network visibility is control-plane state, not Helm inventory.**
  Operators enable host-network visibility from the settings UI or an equivalent
  API. Core persists that assignment/profile state, derives affected agents from
  registry/status metadata, compiles effective agent config, and uses
  agent-gateway's existing command bus/control stream to push config changes to
  connected agents. Local network/process observations travel agent-up for
  bounded core persistence and correlation with independently ingested
  NetFlow/IPFIX. Static Helm `host_slices` were a demo canary and are not a
  production dependency; production scale cannot require one values entry per
  agent.
- **Manifest is the source of truth for version + schema.** The seeder reads
  `version` and `config_schema` from the in-image `addons/netprobe/addon.yaml` +
  `config.schema.json` (already compiled in via `@config_schema`). Signed artifact
  refs (object_key/sha256/signature, OCI digest) still come from the published
  bundle config, because operators must never be able to assign artifacts the agent
  cannot verify. When the manifest version advances but no matching signed
  artifacts are configured, the seeder stages (does not approve) the new version so
  the gap is visible rather than silently frozen.
- **Advanced grouping via schema hints.** Mark capture/DPI/device-binding
  properties with an `x-serviceradar-ui-advanced` (or reuse the existing
  `x-serviceradar-ui-*`) hint; the web-ng config form renders flagged properties in
  a collapsed "Advanced" section and treats none of them as required. Attribution
  needs only `enabled`.
- **Republish on release** keeps the published artifacts and the seeder's manifest
  version aligned per release tag.
- **Process metadata is required, but not a hot-path attribution source.**
  `cmdline` and container identity are required forensic fields on attributed
  flows. PID/TGID/UID/GID/comm/socket tuple attribution comes from eBPF. Metadata
  enrichment is a separate bounded stage keyed by process generation. The current
  implementation may read procfs only after attribution on rate-limited cold work
  such as cmdline or cgroup-to-container resolution; the long-term implementation
  captures exec arguments and cgroup/container metadata through eBPF so normal
  enrichment does not depend on procfs on busy workers.
- **Procfs is not process/listener discovery.** The always-on attribution path
  must not periodically walk `/proc/net/*` or `/proc/*/fd` to discover listener
  ownership. Those files are generated snapshots and do not provide a reliable
  event API. Netprobe uses eBPF socket/process lifecycle events to maintain
  user-space caches.
- **Socket and process lifecycle events drive inventory.** Existing connection
  attribution probes continue to emit flow events. Listener inventory is maintained
  from kernel events such as TCP socket state/listen/close transitions, UDP
  bind/unbind coverage, and process exec/exit/free events. User space keys socket
  cache entries by socket cookie or socket pointer where available, falling back to
  normalized tuple keys only when the kernel source cannot provide a stable socket
  identity.
- **Snapshots serialize cache state, not host scans.** If downstream services need
  periodic `ProcessSnapshot` messages, netprobe emits a coalesced view of the
  event-maintained cache. Snapshot cadence controls network/update volume only; it
  must not trigger recurring host-wide discovery.
- **Process identity includes a generation marker.** PID-only caches are not safe
  across PID reuse. Process metadata caches include pid/tgid plus a stable
  process-generation value such as kernel start time or an eBPF-observed
  exec/creation timestamp.
- **Correlation ownership is centralized.** The deployed candidate families,
  including wildcard listeners, UDP exporter ephemeral-port mismatch,
  ICMP/ICMPv6 port independence, node-SNAT, and public-endpoint mapping, are
  owned and verified by `harden-flow-attribution-pipeline`. That change also
  resolves the current public-rank collision so exact local matches win
  deterministically. This fleet proposal does not independently narrow or
  reprioritize those rules.
- **Every asynchronous boundary is bounded and observable.** eBPF ring buffers,
  netprobe in-process queues, local UDS delivery, agent sidecar buffers, and agent
  push batches use fixed capacity. When burst traffic exceeds capacity, the system
  increments drop/lag counters and may coalesce status/snapshot events, but it
  must not allocate unbounded memory or silently lose attribution events.
- **Performance gate is part of release readiness.** Attribution-only mode is
  accepted only when representative Linux workers show less than 1% sustained
  process CPU over a multi-minute sample, no persistent ring or delivery drops,
  bounded queue lag and cache growth, continued attribution rows, and no TCP/UDP/
  ICMP hit-rate regression. Packet capture/DPI has its own budget because it is an
  explicit advanced feature.

## Risks / Trade-offs

- Auto-enabling attribution fleet-wide increases eBPF load across many hosts →
  bounded: attribution is the lightweight socket/process lifecycle path; no
  AF_XDP/capture unless explicitly opted in. Always-on code paths must be
  event-driven and must pass the CPU gate above.
- Manifest-driven seeding could surface a version with no signed artifacts → stage
  (not approve) so it is reviewable, never assignable unverified.
- UI advanced-collapse must not hide required fields → attribution requires no
  capture fields, so none of the collapsed fields are required.
- eBPF lifecycle coverage is more complex than procfs scanning → required for the
  performance target. Do not keep recurring procfs discovery in the steady state.
- Larger bounded burst buffers trade memory for fewer IPC drops → acceptable for
  attribution-only mode only when capacity and drop metrics are explicit and the
  release gate verifies memory/CPU remain inside budget.

## Migration Plan

- The frozen demo `netprobe@0.1.0` package is updated in place by the seeder once
  it re-derives version/schema from the manifest (no manual DB edit required after
  deploy). Existing assignments keep working; their params are normalized against
  the new schema.
- No data migration; schema/version changes are additive.
- Existing snapshot consumers continue to receive `ProcessSnapshot` updates. The
  producer changes from procfs reconstruction to cache serialization, so consumers
  do not need a wire-level migration.

## Open Questions

- Should capture-interface auto-detection (default-route-aware, never the primary
  NIC) ship here or as a separate capture-focused change? (Proposed: separate.)
- Where do signed artifact refs live long-term — derived from the published import
  index automatically, vs. the current runtime config? (Proposed: wire the
  native-addons import index into the seeder config as a follow-up.)
