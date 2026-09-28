## Goal and ownership

Required completion proof for #4774/#4901, not a deferred platform enhancement. Run the actual authenticated product against an independently invented million-device topology, with animated edges driven by invented SNMP counters through JetStream/EventWriter. These are simulated devices; no physical SNMP fleet is required.

Existing production-encoded Arrow/browser fixtures, physical-GPU measurements and the scratch layout/persistence benchmark are useful evidence, but their mocked telemetry/channel paths do not prove this end-to-end scenario.

## Implementation slices

1. Generate 1,000,000 invented simulated devices and at least 2,000,000 relations using the existing native hierarchy generator where possible. No physical devices or WASM plugin are required. Use bounded batches with stable identities, hierarchical links and explicit interface bindings.
2. Prefer existing topology import/API paths. Controlled direct topology seeding into owned isolated storage is also allowed for this scale proof; record the storage boundary and bypassed discovery/ingestion layers. Completing the separate plugin topology-link contract is not a prerequisite.
3. Emit invented cumulative SNMP packet and octet counters with a native publisher or optional SDK emit_telemetry -> JetStream -> EventWriter -> the selected telemetry backend. Preserve interface identity, width/reset semantics and producer identity. Multicast/broadcast are optional; ordinary in/out packet or bit rates must animate traffic.
4. Provision an isolated synthetic deployment/graph and storage. An existing CI service does not authorize overwriting its shared graph. Increase small -> medium -> million profiles only after exact counts, resource budgets and freshness pass.
5. Use the authenticated topology manifest/tiles, channel, SRQL overlays and hardware WebGPU browser with traffic on.

## Acceptance

- [ ] Exact persisted device/relation counts and interface bindings are verified after loading; the report distinguishes inventory, graph and world-position counts and discloses bypassed ingestion layers; retry/restart does not duplicate records.
- [ ] Record total topology population separately from active telemetry interfaces, sample cadence, offered records/sec, backlog and freshness. A smaller traffic cohort is not advertised as million-device telemetry throughput.
- [ ] Initial Home view has correct aggregate counts and documented center/zoom/coverage. Zoom reveals infrastructure/endpoints; search flies to a device; bounded ELK detail works and returns to the map.
- [ ] Real changing metrics produce directional animated edges, including nonzero -> zero, stopped/stale reporting, reset/wrap and resumed traffic. No mocked overlay or direct-to-database metrics satisfy this check.
- [ ] Telemetry updates fetch no geometry; cached revisits and targeted invalidations behave correctly within feature/byte/memory budgets.
- [ ] At 1M devices on a real GPU with traffic enabled: first usable frame <=3s, pan/zoom >=30 FPS, hover/select <100ms and local tile fetch+decode p95 <=200ms. Record hardware, browser, commit, seed, configuration and failures.
- [ ] Provide a repeatable launch/verification procedure and visual evidence. Stop owned producers and query owned records after cleanup.

## Proposal ownership

This proposal owns its own tasks and deltas. See proposal.md for dependencies.

## Simulator design

Prefer the existing native million-device hierarchy generator and production
world publication API. A native fixture publisher, existing import/API or
controlled direct topology seed into owned isolated storage can provide this
proof. WASM and the showcase plugin topology-link contract are optional, not
prerequisites. Reuse simkit primitives where they help without requiring a new
plugin or pretending to poll one million physical SNMP devices.

The scenario is independently invented and deterministic: hierarchical sites,
backbone routers, switches, endpoints and redundant links. Device/relation IDs
and interface indices remain stable across retries. Stream bounded batches for
one million devices and at least two million relations. Verify actual counts in
each populated store; a world-position count alone is not evidence of a million
inventory or Dgraph device records. Report which layers were seeded and which
normal discovery/identity/provenance paths were bypassed. This validates the
mapping engine and downstream telemetry path, not any bypassed ingestion path.

SNMP traffic uses the existing SDK metric envelope, with metric type `snmp`,
interface index, counter width, cumulative kind, monotonic flag and producer
identity. Start with `ifHCInUcastPkts`, `ifHCOutUcastPkts`, `ifHCInOctets` and
`ifHCOutOctets`. Octet derivatives become bit rates by multiplying by eight.
Multicast and broadcast are optional counter families, not prerequisites for
traffic animation. Use simkit's restart-safe counters and fault scheduler for
bidirectional load, idle links, loss of observations and explicit device-reboot
counter resets. A native publisher may submit valid SNMP metric envelopes directly to the
appropriate JetStream subject; a WASM producer may use `emit_telemetry`. Both
use EventWriter and the deployment-selected telemetry backend. No direct
database metric writes are permitted.

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
