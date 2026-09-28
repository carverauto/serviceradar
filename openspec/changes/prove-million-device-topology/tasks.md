## 1. Implementation

- [ ] 1.1 Reuse demo/simkit and the existing demo-only WASM packaging path. Generate stable identities for 1,000,000 devices and at least 2,000,000 relations with a hierarchical backbone, redundant paths and explicit interface bindings. Shard generation and batches within current host limits; do not materialize the whole network in one Wasm invocation.
- [ ] 1.2 Audit/complete add-showcase-demo-portfolio D10/tasks 7.x topology-link admission and Go/Rust contracts. Ingest through canonical identity/provenance handling into Dgraph; no direct graph seed that bypasses the product contract.
- [ ] 1.3 Emit cumulative SNMP packet and octet counters via SDK emit_telemetry -> JetStream -> EventWriter -> the selected telemetry backend. Preserve interface identity, width/reset semantics and producer identity. Multicast/broadcast are optional; ordinary in/out packet or bit rates must animate traffic.
- [ ] 1.4 Provision an isolated synthetic deployment/graph and storage. An existing CI service does not authorize overwriting its shared graph. Increase small -> medium -> million profiles only after exact counts, resource budgets and freshness pass.
- [ ] 1.5 Use the authenticated topology manifest/tiles, channel, SRQL overlays and hardware WebGPU browser with traffic on.

## 2. Acceptance

- [ ] Exact persisted device/relation counts and interface bindings are verified after ingestion; retry/restart does not duplicate records.
- [ ] Record total topology population separately from active telemetry interfaces, sample cadence, offered records/sec, backlog and freshness. A smaller traffic cohort is not advertised as million-device telemetry throughput.
- [ ] Initial Home view has correct aggregate counts and documented center/zoom/coverage. Zoom reveals infrastructure/endpoints; search flies to a device; bounded ELK detail works and returns to the map.
- [ ] Real changing metrics produce directional animated edges, including nonzero -> zero, stopped/stale reporting, reset/wrap and resumed traffic. No mocked overlay or direct-to-database metrics satisfy this check.
- [ ] Telemetry updates fetch no geometry; cached revisits and targeted invalidations behave correctly within feature/byte/memory budgets.
- [ ] At 1M devices on a real GPU with traffic enabled: first usable frame <=3s, pan/zoom >=30 FPS, hover/select <100ms and local tile fetch+decode p95 <=200ms. Record hardware, browser, commit, seed, configuration and failures.
- [ ] Provide a repeatable launch/verification procedure and visual evidence. Stop owned producers and query owned records after cleanup.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
