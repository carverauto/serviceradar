## ADDED Requirements

### Requirement: AWX Hosts Bind To Proxmox Guests Only On Machine Evidence
The system SHALL bind an AWX inventory host to a Proxmox guest only when the guest reports the address the AWX host declares or the two share a universally administered MAC, and no universally administered MAC contradicts the binding.
A Proxmox node name and VMID only narrow the candidate guests. Proxmox clusters reuse both, and
an AWX host does not identify its cluster, so the pair SHALL NOT bind an AWX host to a guest on
its own, and a lone candidate SHALL be held to the same evidence. When more than one candidate
guest has evidence, the AWX host SHALL bind none. An AWX host bound to no guest stays its own
record: it SHALL NOT take any guest's MACs and SHALL NOT be merged with reason
`awx_proxmox_network_match`. A bound guest SHALL contribute only its universally administered
MACs to the AWX host.

A locally administered MAC SHALL NOT bind an AWX host to a guest, SHALL NOT identify an existing
device as the AWX host's holder, and SHALL NOT count as a MAC overlap that corroborates an AWX
host's address match. Any MAC MAY still contradict a match, and a shared locally administered
MAC SHALL NOT suppress a contradiction between the universally administered MACs of both sides.

When Proxmox enrichment considers existing AWX records as candidates for a guest, the same rule
SHALL apply: a matching node name and VMID SHALL NOT let the guest adopt or merge an AWX record
unless the guest reports the AWX host's declared address or an address of the AWX record.

#### Scenario: A lone guest of another cluster with the same node name and VMID
- **GIVEN** a Proxmox guest with node `pve01` and VMID 100 that reports address A
- **WHEN** an AWX host with node `pve01`, VMID 100 and `ansible_host` B arrives
- **THEN** the AWX host SHALL NOT be bound to the guest
- **AND** the AWX record SHALL NOT be merged with the guest's device

#### Scenario: Guests of two clusters both report the declared address
- **GIVEN** two Proxmox guests from different clusters, each with node `pve01` and VMID 100, both reporting address A
- **WHEN** an AWX host with node `pve01`, VMID 100 and `ansible_host` A arrives
- **THEN** the AWX host SHALL be bound to neither guest

#### Scenario: The guest of the host's own cluster reports its address
- **GIVEN** two Proxmox guests with node `pve01` and VMID 100, one reporting address A and the other address B
- **WHEN** an AWX host with node `pve01`, VMID 100 and `ansible_host` A arrives
- **THEN** the AWX record SHALL merge into the device of the guest reporting A
- **AND** the guest reporting B SHALL NOT be merged

#### Scenario: A shared universally administered MAC binds the guest
- **GIVEN** two Proxmox guests with node `pve01` and VMID 100, each reporting its own address, with different universally administered NIC MACs
- **WHEN** an AWX host with node `pve01` and VMID 100 declares no address and declares the first guest's MAC
- **THEN** the AWX record SHALL merge into the first guest's device

#### Scenario: A locally administered MAC binds no guest
- **GIVEN** a Proxmox guest with node `pve01` and VMID 100 that reports a locally administered MAC
- **WHEN** an AWX host with node `pve01` and VMID 100 declares that MAC and an address the guest does not report
- **THEN** the AWX host SHALL NOT be bound to the guest

#### Scenario: A shared locally administered MAC does not corroborate a holder
- **GIVEN** an agent-managed device holding the locally administered MAC `EE:EE:EE:EE:EE:EE`
- **WHEN** an AWX host declaring only that MAC arrives
- **THEN** the AWX record SHALL NOT be merged into the device

#### Scenario: Proxmox enrichment does not adopt an AWX record on node name and VMID
- **GIVEN** an AWX record declaring node `pve01`, VMID 100 and `ansible_host` A
- **WHEN** Proxmox enrichment reports a guest with node `pve01` and VMID 100 and no address
- **THEN** the guest SHALL NOT adopt or merge the AWX record

### Requirement: AWX Inventory Sync Reports Hosts Without Asserting Machine Identity
The AWX inventory sync producer SHALL emit an AWX host whose variables declare an IP
`ansible_host` or `ansible_ssh_host`, a configured NIC MAC, or a Proxmox guest reference (node name
and VMID), and SHALL skip a host that declares none of them. Emitting a host SHALL NOT assert
machine identity: only a declared IP and a universally administered MAC are machine evidence. The
producer SHALL emit a Proxmox node name and VMID only as descriptive metadata, which core uses to
narrow guest candidates. A host whose only declarations are a Proxmox guest reference or a locally
administered MAC SHALL still be emitted, because leaving it out of a complete aggregate would
expire its AWX membership and retire its record; core keeps it as its own AWX record.

#### Scenario: A host that declares only a Proxmox guest reference
- **GIVEN** an AWX host whose variables declare node `pve01` and VMID 104 and no address or MAC
- **WHEN** AWX inventory sync runs
- **THEN** the host SHALL be emitted with the node name and VMID as metadata
- **AND** it SHALL NOT be bound to a Proxmox guest on that pair

#### Scenario: A host that declares only a locally administered MAC
- **GIVEN** an AWX host whose only NIC MAC is locally administered and that declares no address
- **WHEN** AWX inventory sync runs
- **THEN** the host SHALL be emitted

#### Scenario: A host known by name alone
- **GIVEN** an AWX host whose variables declare no IP, no NIC MAC and no Proxmox guest reference
- **WHEN** AWX inventory sync runs
- **THEN** the host SHALL NOT be emitted

### Requirement: Proxmox Guest Node Names Come From Node References
When the system reads a Proxmox node name from a v3 provider reference, it SHALL parse the
reference as `IntegrationIdentity` renders it, `proxmox:v3:<integration-uuid>:<controller-uuid>:<cluster>:<kind>:<native-id>`,
and SHALL take the node name only from a `node` reference. A v3 guest reference names no node, so
a guest's node name SHALL come from the guest's metadata or its host's node reference. A child
reference, such as a disk or NIC reference, SHALL NOT yield a node name.

#### Scenario: A guest whose host is in a cluster named like a reference kind
- **GIVEN** a Proxmox guest on node `pve01` whose cluster is named `host`
- **WHEN** the system reads the guest's node name from its host reference
- **THEN** the node name SHALL be `pve01`

#### Scenario: A v3 guest reference
- **GIVEN** the v3 reference of a QEMU guest with VMID 100
- **WHEN** the system reads a node name from it
- **THEN** it SHALL find none
