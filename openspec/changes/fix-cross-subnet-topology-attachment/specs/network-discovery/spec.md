## ADDED Requirements

### Requirement: Cross-subnet FDB attachment reach

The mapper SHALL emit an SNMP-L2 endpoint-attachment topology link when a
forwarding-database (FDB) MAC learned on a managed switch resolves to a
management IP through ARP evidence, regardless of whether that IP falls within
the same IPv4 /24 as the observing switch's own interface addresses. The
MAC→IP resolution step MUST NOT be gated on subnet locality between the switch
and the endpoint.

#### Scenario: Endpoint on a routed VLAN attaches to its switch

- **WHEN** a switch managed on `192.168.1.0/24` has MAC `M` on bridge port `P`,
  and ARP evidence available to the job resolves `M` to `192.168.2.11`
- **THEN** the mapper emits an endpoint-attachment link from the switch port `P`
  to the endpoint identified by `192.168.2.11`
- **AND** the link is not suppressed because `192.168.2.11` is outside the
  switch's own /24

#### Scenario: Same-subnet endpoint still attaches

- **WHEN** an endpoint's resolved IP is within the observing switch's own /24
- **THEN** the attachment link is still emitted (the reach change is additive and
  does not regress same-subnet attachment)

### Requirement: Q-BRIDGE and per-VLAN FDB walk

The mapper SHALL read forwarding-database entries from the Q-BRIDGE-MIB
(`dot1qTpFdbPort`) in addition to the legacy BRIDGE-MIB (`dot1dTpFdbPort`). For
switches that expose forwarding entries only under VLAN-scoped SNMP community
contexts, the mapper SHALL, when the discovery credential permits it, enumerate
the switch's VLANs and walk each per-VLAN community context (`community@vlan`).

#### Scenario: dot1q-only switch yields FDB evidence

- **WHEN** a managed switch returns forwarding entries via `dot1qTpFdbPort` but
  an empty `dot1dTpFdbPort` table
- **THEN** the mapper reads the Q-BRIDGE FDB and produces attachment evidence for
  the learned MACs and their VLAN association

#### Scenario: Per-VLAN community indexing

- **WHEN** a switch exposes its bridge FDB only under VLAN-indexed community
  contexts and the discovery credential is configured to allow `community@vlan`
- **THEN** the mapper enumerates the switch's configured VLANs and walks the FDB
  in each VLAN context, merging the results with a VLAN tag

### Requirement: Router ARP attachment evidence

The mapper SHALL contribute a walked L3 gateway's ARP table
(`ipNetToMediaPhysAddress`) to the shared per-job MAC→IP resolution map, so a
router that exposes ARP but no bridge forwarding database still supplies MAC→IP
evidence to FDB attachment joins on other walked devices in the same job. Router
ARP-only observations without a corresponding bridge port MAY remain
candidate-only for direct publication, but they MUST NOT be excluded from the
shared MAC→IP resolution evidence.

#### Scenario: Router ARP resolves a switch FDB MAC

- **WHEN** router `R`'s ARP maps MAC `M` to `192.168.10.33`, and switch `S`
  (which has no ARP entry for `M`) has `M` on port `P`
- **THEN** the mapper resolves `S:P` to `192.168.10.33` using `R`'s ARP evidence
  and emits the endpoint-attachment link

#### Scenario: Router-only ARP sighting stays candidate-only for direct publish

- **WHEN** a MAC appears in a router's ARP table but on no walked switch's bridge
  port
- **THEN** the mapper may withhold a directly published attachment link for it,
  but still exposes the MAC→IP mapping to the shared resolution map

### Requirement: Recursive-pass endpoint attachment veto removal

The mapper SHALL NOT suppress an FDB-port-mapped endpoint attachment solely
because the endpoint's resolved IP is present in the recursive scan queue
(known-IP set) while its neighbor identity was derived from a cross-device ARP
observation. Endpoint-attachment emission MUST be independent of whether the
observing switch was reached in the first discovery pass or a recursive pass.

#### Scenario: Endpoint discovered during recursive discovery still attaches

- **WHEN** a switch is walked during recursive discovery, and one of its FDB
  endpoints has an IP that is present in the ARP-derived scan queue
- **THEN** the mapper still emits the endpoint-attachment link for it
- **AND** the known-IP-without-registered-identity veto does not fire for an
  endpoint whose identity was resolved by cross-device ARP observation

#### Scenario: Parity between first-pass and recursive-pass switches

- **WHEN** two switches serve comparable endpoint populations, one reached in the
  first pass and one only in a recursive pass
- **THEN** both emit endpoint-attachment links for their FDB endpoints

### Requirement: UniFi wired-client switch-port attachment

The UniFi API discovery path SHALL emit endpoint-attachment topology evidence for
wired clients, associating the client (by MAC and, when present, IP) with the
switch and switch port the controller reports, in addition to existing wireless
client associations. When the controller API omits per-port detail, the mapper
SHALL emit a switch-level attachment (client to switch) at reduced confidence
rather than dropping the wired client.

#### Scenario: Wired client with switch and port

- **WHEN** the UniFi controller reports a wired client with an uplink switch MAC
  and switch port
- **THEN** the mapper emits an endpoint-attachment link from the switch port to
  the client

#### Scenario: Wired client without port detail

- **WHEN** the controller reports a wired client's uplink switch but no port
- **THEN** the mapper emits a switch-level attachment link at reduced confidence
  and does not discard the client

### Requirement: Identifier-aware topology neighbor resolution

Core topology neighbor resolution SHALL consult the canonical device identity
graph (`platform.device_identifiers`) — not only the `ocsf_devices` ip/mac/name
columns — when binding a topology sighting's neighbor (chassis MAC, management
address, or system name) to a canonical device. A sighting carrying an
identifier that the identity graph already associates with a canonical device
MUST bind to that device.

#### Scenario: Sighting on a registered secondary MAC binds to the device

- **WHEN** a topology sighting carries chassis MAC `M`, and `M` is a registered
  identifier of canonical device `D` but is not `D`'s primary `ocsf_devices.mac`
- **THEN** neighbor resolution binds the sighting to `D` via the identity graph,
  rather than leaving it unresolved or minting a provisional device

#### Scenario: Resolution falls back to direct columns

- **WHEN** a sighting's neighbor has no matching row in the identity graph but
  does match an `ocsf_devices` ip/mac/name
- **THEN** resolution still binds via the direct column match (identity-graph
  lookup is additive, not a replacement)

### Requirement: LLDP and CDP endpoint attachment promotion

Endpoint attachment identity promotion SHALL accept direct-physical LLDP and CDP
endpoint sightings as promotable sources, in addition to ARP/FDB port mappings
and UniFi client associations. An endpoint observed only via LLDP or CDP on a
managed switch port whose neighbor identity resolves or is promotable MUST be
eligible to become or bind to a canonical device and receive an attachment link.

#### Scenario: LLDP-only endpoint is promotable

- **WHEN** a managed switch reports an LLDP neighbor that is an endpoint (not
  managed infrastructure) whose chassis MAC or management address resolves to, or
  is promotable to, a canonical device
- **THEN** the endpoint is promoted or bound and an endpoint-attachment link is
  emitted for it

#### Scenario: Infrastructure LLDP neighbors keep direct-physical semantics

- **WHEN** an LLDP neighbor is managed infrastructure (switch/router/AP)
- **THEN** it continues to be handled as a direct-physical backbone link and is
  not reclassified as a promoted endpoint attachment
