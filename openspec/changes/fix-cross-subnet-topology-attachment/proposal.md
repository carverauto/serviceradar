# Change: Fix cross-subnet topology attachment (hypervisor / endpoint islands)

## Why

On the demo network, hypervisors and endpoints on routed segments render as
disconnected "islands" in the topology graph. The `farm01` site
(`192.168.2.0/24`) and the `tonka01` site (`192.168.10.0/24`) devices — including
every Proxmox hypervisor and its guests — have **zero** switch↔host attachment
edges, even though the switches that serve them are discovered and their ARP/FDB
data is reachable over SNMP right now.

A verified investigation (live `snmpwalk` + CNPG/AGE inspection + full Go/Elixir
code trace, adversarially re-derived) shows the canonical topology graph is one
64-node component confined to the `192.168.1.0/24` management net, and the
SNMP-L2 attachment pipeline **structurally cannot emit or bind** attachment edges
for an endpoint whose L3 gateway is a different device than the observing switch.

Verified root causes:

- **[A] Same-/24 join gate.** The SNMP-L2 MAC→IP join is hard-gated to the
  observing switch's own IPv4 /24 (first-three-octet key, `snmp_l2_identity.go:72`;
  enforced at `snmp_l2_query.go:42,143` and `snmp_l2_observed.go:125`). A switch
  managed on `192.168.1.x` can never attach an endpoint whose management IP is on
  `192.168.2.x`.
- **[B] BRIDGE-MIB (dot1d) only.** The FDB walk reads only `dot1dTpFdbPort`
  (`snmp_l2_bridge.go:33,53`); `dot1qTpFdbPort` (Q-BRIDGE) is never walked and a
  single SNMP community is used with no per-VLAN context. VLAN-aware switches that
  expose their FDB only via dot1q (the farm-site UniFi USW-Pro-24) are invisible.
- **[C] Router ARP discarded.** Routers expose no BRIDGE-MIB and their L3 ARP is
  emitted `candidate_only` (`snmp-arp-only`) and dropped before publish in several
  places (`discovery_topology_publish.go:49`, `grpc.go:348`, agent
  `mapper_service.go:337,672`). The one source that knows the routed VLANs'
  MAC→IP mappings never reaches the FDB join.
- **[D] Recursive-pass endpoint veto.** The known-IP-without-identity veto
  (`snmp_l2_query.go:210`: `fdbPortMapped && neighborKnown && !neighborIdentified`)
  drops FDB endpoints in the recursive discovery pass because the ARP-derived scan
  queue feeds `knownDeviceIPv4Set` while cross-device observed joins are always
  `neighborIdentified=false`. First-pass UniFi switches escape it; recursively
  reached switches (the aruba) do not.
- **[E] UniFi wired clients discarded.** The UniFi API path keeps only wireless
  clients at fetch (`ubnt_api.go:112-119`); the port-table path emits zero rows
  (the Integration v1 API carries no `port_table`). Wired clients — the farm-site
  hypervisors on the USW-Pro-24 — produce no attachment edges.
- **[F2] Resolution ignores the identity graph.** Core topology neighbor
  resolution (`mapper_results_ingestor.ex` `resolve_topology_uid` /
  `build_topology_device_index`) consults only `ocsf_devices` (ip/mac/name) and
  never `platform.device_identifiers`, so a sighting on a device's secondary MAC
  cannot bind even when DIRE already knows that MAC.
- **[G] LLDP/CDP endpoints not promotable.** Endpoint attachment promotion
  enumerates ARP/FDB + UniFi client sources only
  (`@endpoint_attachment_sighting_sources`), excluding direct-physical LLDP/CDP
  endpoint sightings (e.g. a server 10G NIC advertising LLDP on a switch port).

Live proof the data is sufficient: on the tonka aruba switch (`192.168.10.154`,
HP 2920), all five endpoints on ports 13–17 resolve via `tonka01`'s ARP to
existing inventory IPs (`192.168.10.31/.33/.45/.56/.96`) on the **same /24** as
the switch — so only **[D]** blocks those edges. The switch's `dot1d` FDB walks
fine (`dot1q` adds only VLAN duplicates), so **[B]** is not the tonka blocker. On
the farm site the pve hosts sit on VLAN 2 of the UniFi USW-Pro-24, reachable only
via `dot1q` (**[B]**) and on a different /24 than the switch (**[A]**), and are
learned as wired controller clients (**[E]**).

## What Changes

Seven new `network-discovery` requirements, grouped by pipeline stage. All are
**ADDED** — none modifies `Mapper topology ingestion and graph projection` (that
requirement is co-modified by `improve-mapper-topology-fidelity` and
`add-multipath-topology-discovery`; this change stays off it).

- **Emission reach (Go mapper):** [A] cross-subnet FDB attachment reach,
  [B] Q-BRIDGE / per-VLAN FDB walk, [C] router ARP as shared join evidence,
  [D] recursive-pass endpoint attachment veto removal.
- **Controller path (Go mapper):** [E] UniFi wired-client switch-port attachment.
- **Binding (core-elx):** [F2] identifier-aware topology neighbor resolution,
  [G] LLDP/CDP endpoint attachment promotion.

## Impact

- **Affected specs:** `network-discovery` (7 ADDED requirements).
- **Affected code:**
  - `go/pkg/mapper/snmp_l2_identity.go`, `snmp_l2_query.go`, `snmp_l2_bridge.go`,
    `snmp_l2_observed.go`, `discovery_recursive.go`, `discovery_topology_publish.go`
  - `go/pkg/mapper/ubnt_api.go`, `ubnt_topology.go`, `ubnt_models.go`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
    (neighbor resolution index + endpoint-attachment sighting sources)
- **Composes with (does NOT modify):** `improve-mapper-topology-fidelity`
  (recursive coverage + neighbor identity completeness assume these emission fixes
  exist), `fix-topology-evidence-pipeline-resilience` (endpoint promotion binds
  the rows this change makes emittable; [G] extends its promotable-source set),
  `add-unifi-wifi-discovery-parity` (requires wired-client *fetch*; [E] adds the
  wired-client switch-port *attachment* edge on top), `add-multipath-topology-discovery`.

## Out of Scope / Related Work

The islands also depend on the following, tracked separately to avoid colliding
with in-flight changes. The linked forgejo issue enumerates all of them.

- **UI display (finding H) — treat as bug fixes, fold into
  `refactor-topology-read-model-for-carrier-scale`.** The god-view NIF drops
  `relation_type`/`topology_plane` (`god_view_nif/src/core/utils.rs:282-288`), so
  real `ATTACHED_TO` edges misclassify as `inferred` and are hidden by the default
  layer set; and any hosted-edge-incident node is force-islanded
  (`layout_topology_state_methods.js:679-707,995`) even when it has a genuine
  backbone/attachment edge. These land in files that change is rewriting; a
  parallel spec delta would conflict, so they are not specced here.
- **Proxmox cross-site over-merge (finding I) + host NIC MAC absence (F1) —
  device-inventory / identity territory.** `virtualization_hosts` is keyed on an
  unscoped `proxmox:node:<name>` provider_ref, collapsing the two clusters'
  same-named nodes into chimera devices; PVE `/nodes/<n>/network` returns no
  `hwaddr`, so hypervisor NIC MACs are never registered. Owner
  `refactor-provider-neutral-hypervisor-enrichment` is already Complete; these need
  a follow-up (cluster-scoped host identity + host NIC MAC registration).
- **Proxmox enrichment stall (finding J) — operational.** The credential-rule
  reconcile is failing on demo (`failed_agents=2`), freezing `virtualization_*`;
  add failure surfacing via `fix-proxmox-inventory-plugin-reliability`.
