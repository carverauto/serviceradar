## Goal and ownership

Required completion proof for #4774/#4901, not a deferred platform enhancement. Run the actual authenticated product against an independently invented million-device topology, with animated edges driven by synthetic SNMP counters through the normal ingestion path.

Existing production-encoded Arrow/browser fixtures, physical-GPU measurements and the scratch layout/persistence benchmark are useful evidence, but their mocked telemetry/channel paths do not prove this end-to-end scenario.

## Implementation slices

1. Reuse demo/simkit and the existing demo-only WASM packaging path. Generate stable identities for 1,000,000 devices and at least 2,000,000 relations with a hierarchical backbone, redundant paths and explicit interface bindings. Shard generation and batches within current host limits; do not materialize the whole network in one Wasm invocation.
2. Audit/complete add-showcase-demo-portfolio D10/tasks 7.x topology-link admission and Go/Rust contracts. Ingest through canonical identity/provenance handling into Dgraph; no direct graph seed that bypasses the product contract.
3. Emit cumulative SNMP packet and octet counters via SDK emit_telemetry -> JetStream -> EventWriter -> the selected telemetry backend. Preserve interface identity, width/reset semantics and producer identity. Multicast/broadcast are optional; ordinary in/out packet or bit rates must animate traffic.
4. Provision an isolated synthetic deployment/graph and storage. An existing CI service does not authorize overwriting its shared graph. Increase small -> medium -> million profiles only after exact counts, resource budgets and freshness pass.
5. Use the authenticated topology manifest/tiles, channel, SRQL overlays and hardware WebGPU browser with traffic on.

## Acceptance

- [ ] Exact persisted device/relation counts and interface bindings are verified after ingestion; retry/restart does not duplicate records.
- [ ] Record total topology population separately from active telemetry interfaces, sample cadence, offered records/sec, backlog and freshness. A smaller traffic cohort is not advertised as million-device telemetry throughput.
- [ ] Initial Home view has correct aggregate counts and documented center/zoom/coverage. Zoom reveals infrastructure/endpoints; search flies to a device; bounded ELK detail works and returns to the map.
- [ ] Real changing metrics produce directional animated edges, including nonzero -> zero, stopped/stale reporting, reset/wrap and resumed traffic. No mocked overlay or direct-to-database metrics satisfy this check.
- [ ] Telemetry updates fetch no geometry; cached revisits and targeted invalidations behave correctly within feature/byte/memory budgets.
- [ ] At 1M devices on a real GPU with traffic enabled: first usable frame <=3s, pan/zoom >=30 FPS, hover/select <100ms and local tile fetch+decode p95 <=200ms. Record hardware, browser, commit, seed, configuration and failures.
- [ ] Provide a repeatable launch/verification procedure and visual evidence. Stop owned producers and query owned records after cleanup.

## Proposal ownership

This proposal owns its own tasks and deltas. See proposal.md for dependencies.

## Simulator design

Use the existing `demo/simkit` and demo-only WASM build/publish path for a
reusable network scenario. The existing Armis faker remains an API emulator;
this scenario needs stable network relations and interface-bound counters as
well as device records. No second simulation clock or counter engine is needed.

The scenario is independently invented and seed-derived: hierarchical sites,
connected backbone routers, switches, endpoints and redundant physical links.
Device and relation identities and interface indices are stable across retries.
The million-device profile has at least two million relations. Inventory and
link generation is streamed in bounded assignment shards; a single WASM run
must never materialize the whole graph or exceed the existing result, telemetry,
memory and timeout limits. The shard size is chosen from measured payload and
runtime limits, not by raising those limits to fit the scenario.

Complete D10's plugin topology ingestion before using it for this proof. Links
need endpoint identities, local/remote interface indices, evidence class and
source observation timestamps. Physical links must enter the canonical Dgraph
writer with real interface attribution. Synthetic does not mean bypassing
identity reconciliation, provenance or expiry. The ordinary ingestion contract
must support retries and establish devices before links reference them.

SNMP traffic uses the existing SDK metric envelope, with metric type `snmp`,
interface index, counter width, cumulative kind, monotonic flag and producer
identity. Start with `ifHCInUcastPkts`, `ifHCOutUcastPkts`, `ifHCInOctets` and
`ifHCOutOctets`. Octet derivatives become bit rates by multiplying by eight.
Multicast and broadcast are optional counter families, not prerequisites for
traffic animation. Use simkit's restart-safe counters and fault scheduler for
bidirectional load, idle links, loss of observations and explicit device-reboot
counter resets. All samples go through the agent host's `emit_telemetry` path,
JetStream and EventWriter; no direct database metric writes.

Topology population and telemetry population are separately configured and
reported. A million stored devices with a smaller active interface cohort is a
valid topology/renderer test, but is not a million-device telemetry throughput
result. Full-population traffic is an explicit load profile with a declared
sample cadence, offered records per second and measured backlog/freshness.
Scale up only after the preceding profile's ingestion and resource checks pass.

Use an isolated synthetic deployment, including its own graph and telemetry
storage. The presence of a CI Dgraph service is not authorization to overwrite
its shared graph. Automated database tests keep using srql-fixtures scratch
lifecycle ownership. Provisioning and verification are Bazel targets; builds
run on RBE. Stop producers before cleanup and query the owned data afterward.

Acceptance uses the authenticated product, actual HTTP tiles/channel
invalidations, SRQL overlays and a hardware WebGPU browser. Record counts at
ingestion/storage boundaries, initial camera target/zoom and population
coverage, cache behavior, bounded ELK details, traffic transitions and frame
performance. Existing generated Arrow fixtures and mocked telemetry browser
checks remain useful focused tests, but do not establish this pipeline proof.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
