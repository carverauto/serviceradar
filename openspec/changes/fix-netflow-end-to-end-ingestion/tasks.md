## 1. Investigation And Contract Definition
- [ ] 1.1 Inventory every in-repo producer and consumer of `flows.raw.netflow` and confirm the current live payload format.
- [ ] 1.2 Reconfirm protobuf `FlowMessage` as the canonical `flows.raw.netflow` contract and update the Elixir protobuf bindings to match the current `.proto`.
- [ ] 1.3 Document `platform.ocsf_network_activity` as the canonical persisted NetFlow store and `platform.bgp_routing_info` as the derived BGP analytics store.
- [x] 1.4 Document whether any deployment still depends on `flows.raw.netflow.processed` or Zen rule bootstrap for NetFlow UI visibility.

## 2. Collector And Routing Repair
- [ ] 2.1 Update the Rust flow collector to publish protobuf `FlowMessage` bytes on `flows.raw.netflow`.
- [ ] 2.2 Route `flows.raw.netflow` through the canonical OCSF flow processor instead of the raw `netflow_metrics` processor.
- [ ] 2.3 Update EventWriter flow handling so the canonical protobuf message is decoded successfully for `flows.raw.netflow` and persisted to `platform.ocsf_network_activity`.
- [ ] 2.4 Derive BGP observations from the same decoded NetFlow record into `platform.bgp_routing_info` when AS-path data is present.
- [ ] 2.5 Drop the legacy `platform.netflow_metrics` table via migration and delete the obsolete processor/module path.

## 3. Health And Troubleshooting
- [ ] 3.1 Add stage-level counters and last-error reporting for collector receive, publish, decode, OCSF inserts, and derived BGP inserts.
- [ ] 3.2 Surface a degraded or actionable health state when NetFlow messages are received but not reaching the canonical OCSF path.
- [ ] 3.3 Update operational docs/runbooks and smoke-test scripts with concrete verification steps for the repaired path.

## 4. Validation
- [ ] 4.1 Add end-to-end tests covering NetFlow/IPFIX payloads with and without BGP fields.
- [ ] 4.2 Verify a representative NetFlow message produces a row in `platform.ocsf_network_activity` and a derived BGP observation in `platform.bgp_routing_info` when applicable.
- [ ] 4.3 Verify `/flows`, `/netflow`, or equivalent `in:flows` queries return the inserted NetFlow data.
- [ ] 4.4 Verify BGP dashboards or equivalent stats queries continue to return derived NetFlow BGP data without depending on `netflow_metrics`.
- [ ] 4.5 Verify no runtime config, processor, test, or doc path still references `netflow_metrics` as active storage.
- [ ] 4.6 Run `openspec validate fix-netflow-end-to-end-ingestion --strict`.
