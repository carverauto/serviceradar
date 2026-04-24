## 1. Core Configuration

- [x] 1.1 Add a RouterOS discovery resource under `ServiceRadar.NetworkDiscovery` with encrypted credentials and mapper-job ownership.
- [x] 1.2 Add the required Elixir migration(s) under `elixir/serviceradar_core/priv/repo/migrations/` for RouterOS discovery source storage in the `platform` schema.
- [x] 1.3 Extend `MapperJob` relationships and validations to load RouterOS discovery sources alongside existing UniFi sources.
- [x] 1.4 Extend the mapper compiler to emit RouterOS API configuration and per-job selector metadata.
- [x] 1.5 Add resource and compiler tests covering URL normalization, secret redaction, and compiled config output.

## 2. Go Mapper

- [x] 2.1 Add a RouterOS poller/client in `go/pkg/mapper/` using the RouterOS REST API over HTTPS.
- [x] 2.2 Add mapper configuration parsing for RouterOS endpoints and selectors.
- [x] 2.3 Normalize RouterOS system identity, board, and version data into `DiscoveredDevice`.
- [x] 2.4 Normalize RouterOS interfaces, bridge membership, VLAN membership, and IP address data into `DiscoveredInterface`.
- [x] 2.5 Emit topology or neighbor evidence as `TopologyLink` records when RouterOS provides reliable adjacency data.
- [x] 2.6 Tag RouterOS-originated evidence with `mikrotik-api` source metadata.
- [x] 2.7 Add unit tests for partial/unsupported endpoint handling and response-shape normalization.

## 3. Ingestion And Inventory

- [x] 3.1 Extend mapper ingestion to preserve RouterOS source metadata without leaking secrets into stored discovery options.
- [x] 3.2 Map RouterOS vendor, model, version, serial, and architecture data into device inventory enrichment fields.
- [x] 3.3 Add or update inventory tests to verify RouterOS API data improves canonical device classification when present.

## 4. Documentation And Live Validation

- [x] 4.1 Update discovery documentation with RouterOS setup requirements, supported data coverage, and read-only scope.
- [x] 4.2 Document demo validation steps for the live MikroTik CHR target in `demo`.
- [x] 4.3 Run targeted tests for Elixir and Go changes.
- [ ] 4.4 Validate against the live MikroTik CHR environment and record any gaps that should become follow-up issues.

Current status for `4.4`: the `demo` CHR baseline was inspected in CNPG on 2026-03-06 and currently shows shallow SNMP-era inventory (`vendor_name=MikroTik`, `model=RouterOS`, empty `os`/`hw_info`, no topology evidence). Post-deploy validation of the new RouterOS API path is still required.
