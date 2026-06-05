## 1. Agent — attribution without capture (shipped in v1.2.90)
- [x] 1.1 Relax `netprobeConfigHasWork` so `enabled` alone runs netprobe (`go/pkg/agent/push_loop_config.go`)
- [x] 1.2 Verify agent tests cover enable-only launch (`go test ./go/pkg/agent/...`)

## 2. Config schema — attribution-first defaults
- [x] 2.1 Add sensible defaults + clarify `enabled` runs attribution (`addons/netprobe/config.schema.json`)
- [x] 2.2 Mark `capture_interfaces`, `dpi`, `default_sample_interval_ms`, `external_flow_match_window_ms`, `device_bindings` as advanced via `x-serviceradar-ui-advanced` (all non-`enabled` fields)
- [x] 2.3 Confirm no capture field is in the schema `required` set (top-level schema has no `required`)

## 3. Operator form — one-touch
- [x] 3.1 Render `x-serviceradar-ui-advanced` properties in a collapsed `<details>` Advanced section in `plugin_config_form.ex` (extracted `config_field` component; backward-compatible)
- [x] 3.2 Enable is the only inline field; advanced fields collapsed + none required (no `*`, not in `required`)
- [x] 3.3 Copy updated so capture fields read as "Optional" / advanced

## 4. Seeding — manifest-driven
- [x] 4.1 `NetprobeAddonPackageSeeder` derives `version` + `capabilities` from the in-image manifest (`addon.yaml`) instead of hardcoded `@version "0.1.0"`
- [x] 4.2 Seeder always writes the in-image `config_schema` (create or update), so a schema change reaches the seeded package
- [x] 4.3 When no matching signed artifacts are configured, stage (do not approve) the manifest version instead of no-op'ing, so the version + schema become visible; approve only verified versions
- [ ] 4.4 (deferred follow-up) Factor a shared manifest-driven seeding helper; bumblebee + endpoint-inventory seeders still hardcode version/capabilities (~230 lines duplicated each)

## 5. Publish pipeline (shipped in v1.2.90)
- [x] 5.1 `native-addons.yml` triggers on `v*` tags (republish on release)
- [x] 5.2a `runtime.exs` reads `SERVICERADAR_NETPROBE_ADDON_{ARTIFACTS,VERSION,OCI_REF,OCI_DIGEST}` into `:netprobe_native_addon_package`, so the seeder activates + approves once the published signed artifacts are supplied
- [x] 5.2b core helm template (`core.yaml`) passes those env vars from `core.netprobeAddon.{artifacts,version,ociRef,ociDigest}` (guarded — inert unless set; verified rendering)
- [ ] 5.2c (BLOCKED) Populate `core.netprobeAddon` in `values-demo.yaml` from the published `serviceradar-native-addon-index.json`. BLOCKER: the `native-addons.yml` publish FAILED on v1.2.91 (40m59s publish failure on run #16189; no `serviceradar-native-addon-index.json` asset on the release) — so `0.2.0` artifacts were never published. Re-run/dispatch the publish first.
- [ ] 5.2d (follow-up) Wire an auto-importer (the importer exists but is never invoked) so artifact refs track each release with no manual values step
- [ ] 5.2e Fix add-on artifact download drift observed on demo workers: some assigned agents report gateway download `404` or certificate verification failures while leaving the current systemd netprobe unchanged. Validate that a new release exposes a current approved package, agents download it without `403`/`404`/TLS errors, and the UI assignment path succeeds end to end.

## 6. Verification
- [ ] 6.1 On a release, confirm the add-ons UI shows the new netprobe version + updated schema
- [x] 6.2 Assign netprobe (Enable only) to a worker cohort; confirm attribution streams and attributed-flow rows appear with no interface config
- [ ] 6.3 Confirm capture/DPI still works when opted in via advanced settings

## 7. Netprobe performance architecture
- [x] 7.1 Make the attribution ring reader event-driven instead of sleeping/polling between drains
- [x] 7.2 Replace the cross-thread attribution event bridge polling loop with a wake-driven Tokio channel
- [x] 7.3 Cache per-process cmdline/container enrichment so flow events do not repeatedly read `/proc/<pid>/cmdline` and `/proc/<pid>/cgroup`
- [x] 7.4 Add eBPF `sched_process_exec`/`sched_process_exit` lifecycle hooks and carry a process-generation marker into PID reuse-safe enrichment cache keys
- [ ] 7.5 Evaluate whether `sched_process_free` is needed in addition to exit for delayed cleanup on supported kernels
- [ ] 7.6 Add eBPF listener/socket lifecycle events for TCP listen/state/close and UDP bind/unbind coverage
- [x] 7.7 Replace recurring `process_snapshot` procfs listener discovery with a user-space cache fed by lifecycle events; keep procfs only for bounded cold-path metadata enrichment
- [x] 7.8 Add unit/integration coverage proving snapshot emission does not call the procfs listener walker in steady state
- [ ] 7.9 Add bounded queue/drop/lag counters for eBPF ring reads, netprobe IPC delivery, agent sidecar buffers, and gateway push batches
- [ ] 7.10 Add local IPC batching/coalescing for bursty attribution delivery so a slow agent reader drains multiple events per wakeup without unbounded memory growth
- [ ] 7.11 Add protocol-aware OCSF correlation coverage for TCP, UDP, ICMP, ICMPv6, pod-local, and node-SNAT cases
- [ ] 7.12 Add a Linux worker performance smoke script or documented gate that records CPU, ring drops, IPC/queue lag, event rates, cache sizes, attribution row freshness, and protocol hit rates over a multi-minute sample
- [ ] 7.13 Verify attribution-only netprobe stays below 1% sustained process CPU on representative busy Kubernetes workers with no persistent ring drops, IPC lag, queue drops, or attribution hit-rate regressions
- [x] 7.14 Formalize the ServiceRadar attribution backend boundary (`EbpfAttributionBackend` plus bounded `MetadataEnricher`) so eBPF is the only PID/tuple attribution source and procfs is limited to post-attribution cmdline/container enrichment
- [x] 7.15 Surface backend hit/miss, cold procfs metadata reads, and cache-size stats through netprobe Prometheus metrics
- [x] 7.16 Strengthen UDP/ICMP eBPF tuple extraction with `msghdr->msg_name` destination handling for unconnected sockets, matching the RustNet approach
- [x] 7.17 Bound and chunk/coalesce netprobe status snapshots so `Streamed netprobe results` never exceeds the agent-gateway stream chunk limit; preserve flow attribution batches and expose truncation/coalescing counters when snapshot detail is reduced.
- [x] 7.18 Coalesce unchanged hot-flow attribution in eBPF before ring submission, remove tracepoint-close entries from the kernel map, and disable default full-cache attribution replays so busy workers do not process/send per-message UDP records plus periodic 30k-row replay bursts.
- [x] 7.19 Make process snapshot emission dirty/event-driven: repeated unchanged socket records refresh liveness without rebuilding/sorting/serializing the full inventory, while add/remove/prune/material changes still emit snapshots on the 30s heartbeat.
- [x] 7.20 Add a cache-first userspace hot path so repeated flow/PID/process-generation records refresh cached attribution and socket liveness without procfs metadata enrichment or process snapshot entry reconstruction.
- [x] 7.21 Keep process snapshots scoped to durable TCP listener lifecycle records instead of every outbound per-peer flow tuple, preventing high-cardinality UDP/TCP flow attribution from exploding the host process inventory.
- [x] 7.22 Remove synchronous procfs metadata reads from flow attribution: emitted rows use eBPF PID/TGID/UID/GID/comm immediately, while rate-limited cold-path cmdline/container enrichment re-emits cached events when metadata becomes available.
- [x] 7.23 Emit dirty listener snapshots immediately after eBPF ring drains, keeping the 30s snapshot timer as a prune/reconciliation heartbeat instead of delaying real inventory changes behind a longer interval.
- [ ] 7.24 Replace procfs cmdline/container enrichment with eBPF process exec argument capture plus cgroup/container metadata keyed by process generation, keeping procfs out of normal attribution/enrichment on busy workers.
