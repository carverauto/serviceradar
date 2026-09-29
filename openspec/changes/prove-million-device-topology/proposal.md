# Change: God View: prove one million devices with simulated SNMP-driven animated edges

Tracking issue: [#4909](https://github.com/carverauto/serviceradar/issues/4909).

## Why

Required completion proof for #4774/#4901, not a deferred platform enhancement. Run the actual authenticated product against an independently invented million-device topology, with animated edges driven by invented SNMP counters through JetStream/EventWriter. These are simulated devices; no physical SNMP fleet is required.

Existing production-encoded Arrow/browser fixtures, physical-GPU measurements and the scratch layout/persistence benchmark are useful evidence, but their mocked telemetry/channel paths do not prove this end-to-end scenario.

## What Changes

- Generate 1,000,000 invented simulated devices and at least 2,000,000 relations using the existing native hierarchy generator where possible. No physical devices or WASM plugin are required. Use bounded batches with stable identities, hierarchical links and explicit interface bindings.
- Prefer existing topology import/API paths. Controlled direct topology seeding into owned isolated storage is also allowed for this scale proof; record the storage boundary and bypassed discovery/ingestion layers. Completing the separate plugin topology-link contract is not a prerequisite.
- Emit invented cumulative SNMP packet and octet counters with a native publisher or optional SDK emit_telemetry -> JetStream -> EventWriter -> the selected telemetry backend. Preserve interface identity, width/reset semantics and producer identity. Multicast/broadcast are optional; ordinary in/out packet or bit rates must animate traffic.
- Provision an isolated synthetic deployment/graph and storage. An existing CI service does not authorize overwriting its shared graph. Increase small -> medium -> million profiles only after exact counts, resource budgets and freshness pass.
- Use the authenticated topology manifest/tiles, channel, SRQL overlays and hardware WebGPU browser with traffic on.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Demo-only simulator, canonical inventory/topology ingestion, SNMP telemetry path and hardware-browser acceptance. Depends on the engine; plugin work is optional and this is a completion gate for #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
