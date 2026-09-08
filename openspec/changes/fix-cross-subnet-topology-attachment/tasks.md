## 1. Mapper emission reach (Go, `go/pkg/mapper`)

- [x] 1.1 [A] Remove the same-/24 gate from the SNMP-L2 MAC→IP join: allow an FDB
  MAC that resolves via ARP evidence to attach regardless of subnet locality
  (`snmp_l2_identity.go` subnet keying; `snmp_l2_query.go:42,143`,
  `snmp_l2_observed.go:125`). Preserve confidence tiering.
- [x] 1.2 [B] Add a Q-BRIDGE FDB walk (`dot1qTpFdbPort`) alongside `dot1dTpFdbPort`,
  tagging entries with their VLAN (`snmp_l2_bridge.go`).
- [x] 1.3 [B] Add credential-gated per-VLAN community (`community@vlan`) FDB
  enumeration for switches that expose FDB only per VLAN.
- [x] 1.4 [C] Feed L3 router ARP (`ipNetToMediaPhysAddress`) into the shared
  per-job MAC→IP resolution map, with provenance, even though router ARP-only
  sightings stay candidate-only for direct publish
  (`discovery_topology_publish.go`, `grpc.go`, agent `mapper_service.go`).
- [x] 1.5 [D] Scope the known-IP-without-identity veto (`snmp_l2_query.go:210`) so
  it does not fire for FDB endpoints whose identity came from a cross-device ARP
  observation in the recursive pass (`discovery_recursive.go` scan-queue seeding).
- [x] 1.6 Confirm the tonka01 job's recursive expansion walks both the ARP owner
  (`tonka01`) and the FDB owner (aruba) in one run so their evidence can join.

## 2. UniFi wired-client attachment (Go, `go/pkg/mapper`)

- [x] 2.1 [E] Stop discarding wired clients at fetch (`ubnt_api.go:112-119`); carry
  wired clients through the pipeline.
- [x] 2.2 [E] Emit endpoint-attachment evidence for wired clients using the
  controller-reported switch MAC + port when present (`ubnt_topology.go`,
  extend `ubnt_models.go` client struct with switch/port fields).
- [x] 2.3 [E] When per-port detail is absent, emit a switch-level attachment at
  reduced confidence instead of dropping the client; determine whether the
  Integration v1 API or a legacy `/stat/sta` fallback is required.

## 3. Core binding (Elixir, `elixir/serviceradar_core`)

- [x] 3.1 [F2] Extend topology neighbor resolution to consult
  `platform.device_identifiers` in `build_topology_device_index` /
  `resolve_topology_uid` (`mapper_results_ingestor.ex`), with the existing
  `ocsf_devices` ip/mac/name lookup retained as fallback.
- [x] 3.2 [G] Add direct-physical LLDP/CDP endpoint sightings to the promotable
  endpoint-attachment sources (`@endpoint_attachment_sighting_sources`), while
  keeping infrastructure LLDP/CDP neighbors as backbone links.
- [x] 3.3 Ensure a resolved endpoint whose device record is IP-only (no MAC
  identity) binds to that existing device rather than minting a provisional.

## 4. Validation

- [x] 4.1 Go unit/fixture tests: cross-subnet FDB join, dot1q/per-VLAN walk,
  router-ARP shared map, recursive-pass veto scoping, UniFi wired attachment.
- [x] 4.2 Elixir tests: identifier-aware resolution binds a secondary-MAC sighting;
  LLDP/CDP endpoint promotion; IP-only device binding.
- [ ] 4.3 Demo verification: the five aruba endpoints
  (`192.168.10.31/.33/.45/.56/.96`) gain `ATTACHED_TO` edges to `aruba-24g-02`;
  farm-site pve hosts gain attachment to USW-Pro-24 (`192.168.1.131`) once [E]/[B]
  land.
- [ ] 4.4 Regression: same-subnet FDB attachment counts on `192.168.1.0/24` do not
  drop; no provisional-duplicate device explosion from the relaxed gates.

## 5. Coordination (no code here — tracked in the linked forgejo issue)

- [x] 5.1 Sequence after / coordinate with `improve-mapper-topology-fidelity`
  (adjacent `go/pkg/mapper` + `mapper_results_ingestor.ex` diffs).
- [x] 5.2 Confirm `fix-topology-evidence-pipeline-resilience` promotion binds the
  newly-emitted rows; align [G] with its promotable-source allowlist.
- [ ] 5.3 Related-work handoffs: UI display fixes (H) into
  `refactor-topology-read-model-for-carrier-scale`; Proxmox cluster-scoping +
  host NIC MAC (I/F1) follow-up; enrichment-stall alerting (J) into
  `fix-proxmox-inventory-plugin-reliability`.
