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
- [x] 5.2c Supersede manual `core.netprobeAddon` values-demo population with web-ng native add-on sync; published `serviceradar-native-addon-index.json` entries are now discovered/imported from releases instead of copied into Helm values.
- [x] 5.2d Wire an auto-importer (the importer existed but was never invoked) so artifact refs track each release with no manual values step; demo enables sync + auto-approval for the verified first-party `netprobe` add-on only.
- [x] 5.2e Fix add-on artifact download drift observed on demo workers: some assigned agents report gateway download `404` or certificate verification failures while leaving the current systemd netprobe unchanged. Verified `netprobe` `0.2.5` is approved/verified in demo, all seven target assignments report `running`, the public token-gated add-on endpoint returns `200` from `sr-test-pve04` with the expected tarball SHA, and a controlled reinstall on `sr-test-pve04` recreated `versions/0.2.5` without `403`/`404`/TLS errors.
- [x] 5.2f Bump netprobe to `0.2.5` after post-`0.2.3` performance changes so the native add-on publish/import path produces a distinct package instead of reusing the older approved `0.2.3` artifact.
- [x] 5.2g Add a PR CI guard that fails when netprobe native add-on payload changes without a manifest version bump, and fails when `addon.yaml`, `Cargo.toml`, and Bazel `NETPROBE_VERSION` drift apart.

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
- [x] 7.10 Add local IPC batching/coalescing for bursty attribution delivery so a slow agent reader drains multiple events per wakeup without unbounded memory growth
- [ ] 7.11 Add protocol-aware OCSF correlation coverage for TCP, UDP, ICMP, ICMPv6, pod-local, and node-SNAT cases
- [x] 7.11a Wire `EVENT_WRITER_HOST_SLICE_SUBSCRIBER_ENABLED` into core runtime config and enable it in demo so `flow.host-slice.>` records can reach the in-memory attribution joiner.
- [x] 7.11b Fix `flow-collector` host-slice fanout to publish `Flowpb.AttributedFlowMessage` payloads instead of raw `FlowMessage` bytes, matching `HostSliceSubscriber` and `AttributedFlowJoiner` expectations.
- [x] 7.11c Add temporary demo host-slice routing for the known Kubernetes worker agents and the `sr-test-pve04` test host so NetFlow records involving those host IPs are published to `flow.host-slice.<agent_id>` for attribution validation. This is a canary bridge only, not a production routing model.
- [x] 7.11c2 Remove the demo static host-slice routing and stop enabling the host-slice subscriber in the demo overlay so demo attribution uses the agent-up persisted attribution feed plus core-side CNPG correlation instead of Helm-maintained per-agent routing.
- [ ] 7.11d Replace static Helm `host_slices` / `host_slice_allowlist` with DB/settings-driven host-network visibility state. The settings UI stores assignments/profiles, core compiles effective agent config, and agent-gateway pushes config changes through the existing command bus/control stream.
- [ ] 7.11e Add a control-plane-generated host-slice routing feed for flow collectors, keyed by agent identity, partition, current host IPs, and host-network visibility status. Flow collectors must update routes from this feed without Helm redeploys or per-agent values.
- [ ] 7.11f Remove or disable the demo Helm static host-slice entries once the control-plane routing feed is available, and add a scale test proving a 25,000-agent visibility cohort does not grow Helm values.
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
- [ ] 7.24 Preserve cmdline and container ID as required forensic enrichment fields while replacing procfs cmdline/container reads with eBPF process exec argument capture plus cgroup/container metadata keyed by process generation, keeping procfs out of normal attribution/enrichment on busy workers.
- [ ] 7.25 Replace raw `FlowAttributionEventBatch` as the steady-state telemetry feed with a bounded agent-up local network/process observation stream. Core must persist forensic observations even when no NetFlow exists, then correlate with NetFlow/IPFIX when available; netprobe CPU must be fixed by profiling/eBPF/coalescing hot paths, not by requiring a NetFlow down-to-agent replay loop.
- [x] 7.25a Remove the experimental NATS self-subscribe/control-stream external-flow replay path from this branch so the architecture stays agent-up plus core-side correlation.
- [x] 7.25b Fix the k8s-cp3-worker3 netprobe hot path where procfs metadata refresh scanned every cached flow for each process update. Maintain a process-key attribution index and prune/cache-cap live attribution entries independent of resend; live canary improved from 8.15% CPU / ~1.3 GiB RSS to 0.40% CPU / <50 MiB RSS in the first post-restart sample.
- [x] 7.26 Publish/import netprobe `0.2.5` and restart assigned agents so CPU validation runs against the build containing the event-driven snapshot/resend changes. Verified the published amd64 tarball SHA `d5dc220ea5ac2c7e2b15c85577c1324709f3e9e26c0592a188e3a1bb5e0e924f` contains `serviceradar-netprobe` SHA `ad8919a7d8e689ab7774f2a36477353f731e5b1a5fae947ce0ee024584b38a74`; all seven targets have `current -> versions/0.2.5` with that binary hash.
- [ ] 7.27 Refactor `rust/netprobe/src/attribution.rs` into focused modules (eBPF backend, process/socket inventory, metadata enrichment, flow cache/pruning, IPC/status emission, and tests) so future attribution work does not keep accumulating in one oversized file.
- [ ] 7.28 Refactor `rust/netprobe/src/server.rs` into focused modules for IPC accept/read/write framing, request dispatch, visibility config application, event fan-out/backpressure, banner matching, and status/metrics handling; move oversized inline tests into focused Rust integration or module test files under `rust/netprobe/tests/` where that improves readability and compile boundaries.

## 8. Demo/CNPG scale guardrails
- [ ] 8.1 Investigate demo namespace Postgrex/CNPG timeouts observed during netprobe fleet rollout, including `TopologyStateCleanupWorker` 60s queue/check-out timeouts, `ssl recv: closed`, canonical edge telemetry refresh failures, and whether the triggering load is pool starvation, slow topology cleanup, flow/OCSF write amplification, retention debt, or continuous aggregate refresh lag.
- [ ] 8.1a Restore demo Prometheus scrape health for ServiceRadar, CNPG, and pgBouncer metrics; current targets time out because demo NetworkPolicy does not admit `monitoring` namespace scrapes on app/CNPG metrics ports.
- [ ] 8.2 Audit high-volume netprobe, flow, topology, and OCSF write paths for retention policies, Timescale hypertable settings, compression, continuous aggregates, and indexes; add migrations for missing platform-schema policies only.
- [ ] 8.2a Make high-volume observability retention configurable from Helm/runtime config for raw OTEL traces, logs, trace summaries, OCSF/network activity, provider datasets, topology links, scanner results, and vulnerability data.
- [ ] 8.2b Reconcile Timescale retention policies and chunk intervals at runtime so already-migrated clusters honor Helm changes without a one-off migration rerun.
- [ ] 8.2c Reduce demo raw trace/log/trace-summary retention to a short window and set chunk intervals small enough that Timescale can drop expired chunks promptly; prove the 776 GiB apparent footprint is relation data across replicas, not retained WAL.
- [ ] 8.2d Evaluate Timescale compression/hypercore policies for longer-lived hypertables and CAGGs, applying them only where retained chunks live long enough to offset compression CPU/IO; document any one-time compression runbook for oversized historical chunks.
- [x] 8.2e Make raw netprobe flow-attribution staging retention configurable from Helm/runtime config so unmatched observations can be discarded shortly after the correlation window without changing code.
- [ ] 8.2f Design a cold-storage path for high-volume raw network/process observations (for example GCS/S3-compatible object storage with compacted batch export) so SaaS-scale forensic history is not retained directly in CNPG hot tables.
- [ ] 8.3 Add operational scale targets and load-test evidence for thousands of agents and a 50,000-agent design point, including CNPG pool sizing, writer backpressure, cleanup job cadence, CAGG refresh cadence, retention/compression policy lag, and dashboard query latency.
- [ ] 8.4 Add monitoring/runbook coverage for DB pool saturation, long-running topology cleanup, CAGG refresh lag, retention lag, connection checkout latency, and netprobe-induced write amplification.
- [ ] 8.5 Add a regression/perf gate that fails when demo-scale attribution rollout causes Postgrex checkout latency or CNPG query latency to exceed agreed thresholds, so netprobe CPU improvements do not mask database-side saturation.

## 9. Deferred workload/container context enrichment
- [ ] 9.1 Create a dedicated OpenSpec proposal or tracking issue for Kubernetes workload context enrichment: map netprobe container IDs and process attribution to namespace, pod, workload owner, container name/image, node, labels/annotations, and deployment metadata without granting broad Kubernetes API access to the host agent. Evaluate an operator/namespace workload-intel component that runs in-cluster and publishes bounded, signed cluster inventory signals back to ServiceRadar for forensics-grade flow attribution.
- [ ] 9.2 Create the matching non-Kubernetes container context track for Docker and Docker Compose environments: map netprobe container IDs and process attribution to Docker container name, image/digest, labels, Compose project/service/container number, restart policy, network attachments, exposed/published ports, bind mounts, and host path hints so forensics workflows work on single-host and Compose stacks as well as Kubernetes clusters.
- [ ] 9.3 Design the Docker/Compose collection boundary explicitly: prefer runtime metadata already visible from cgroups/containerd where possible; make Docker socket access optional, least-privileged, read-only where supported, separately auditable from netprobe flow attribution, and replaceable by a small local inventory helper for users that do not want the host agent holding Docker API access.
