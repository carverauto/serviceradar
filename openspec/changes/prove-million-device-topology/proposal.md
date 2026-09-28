# Change: God View: prove one million devices with real SNMP-driven animated edges

Tracking issue: [#4909](https://github.com/carverauto/serviceradar/issues/4909).

## Why

Required completion proof for #4774/#4901, not a deferred platform enhancement. Run the actual authenticated product against an independently invented million-device topology, with animated edges driven by synthetic SNMP counters through the normal ingestion path.

Existing production-encoded Arrow/browser fixtures, physical-GPU measurements and the scratch layout/persistence benchmark are useful evidence, but their mocked telemetry/channel paths do not prove this end-to-end scenario.

## What Changes

- Reuse demo/simkit and the existing demo-only WASM packaging path. Generate stable identities for 1,000,000 devices and at least 2,000,000 relations with a hierarchical backbone, redundant paths and explicit interface bindings. Shard generation and batches within current host limits; do not materialize the whole network in one Wasm invocation.
- Audit/complete add-showcase-demo-portfolio D10/tasks 7.x topology-link admission and Go/Rust contracts. Ingest through canonical identity/provenance handling into Dgraph; no direct graph seed that bypasses the product contract.
- Emit cumulative SNMP packet and octet counters via SDK emit_telemetry -> JetStream -> EventWriter -> the selected telemetry backend. Preserve interface identity, width/reset semantics and producer identity. Multicast/broadcast are optional; ordinary in/out packet or bit rates must animate traffic.
- Provision an isolated synthetic deployment/graph and storage. An existing CI service does not authorize overwriting its shared graph. Increase small -> medium -> million profiles only after exact counts, resource budgets and freshness pass.
- Use the authenticated topology manifest/tiles, channel, SRQL overlays and hardware WebGPU browser with traffic on.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Demo-only simulator, canonical inventory/topology ingestion, SNMP telemetry path and hardware-browser acceptance. Depends on the engine and applicable existing plugin topology-link contract; this is a completion gate for #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
