## ADDED Requirements

### Requirement: Agent Host Interface Inventory
The agent SHALL report its host's interface inventory at enrollment and on the control-stream hello, and core SHALL treat only the permanent, globally administered MAC of a physical NIC as strong identity from it.
Each reported interface carries its name, current MAC, permanent MAC when the platform reports
one (a bond member's `perm_hwaddr` included), every IP address, operational state, kind (physical,
bond, bridge, VLAN, virtual, tunnel) and MAC provenance. Loopback is not reported. A bridge, bond
or VLAN counts only through the physical ports it inherits a MAC from; a veth, tap, dummy, SR-IOV
virtual function, randomized, software-assigned, locally administered or reserved MAC is never
identity. The announced address (`host_ip`) and the announced interface's MAC (`host_macs`) are
still reported for cores that predate the inventory. When no reported interface is classified, or
no inventory is reported, core uses `host_macs` as before.

#### Scenario: Only the NICs' permanent MACs are identity
- **GIVEN** an agent whose inventory reports two physical NICs, a bridge inheriting one NIC's MAC, a veth, a tap with a globally administered MAC, and a NIC with a randomized MAC
- **WHEN** the agent checks in
- **THEN** the two NICs' permanent MACs SHALL be the agent's identity MACs
- **AND** the bridge, the veth, the tap and the randomized MAC SHALL NOT be identity

#### Scenario: Guest and container interfaces alone identify nothing
- **GIVEN** an agent whose inventory reports only veth and tap interfaces
- **WHEN** the agent checks in
- **THEN** no MAC SHALL be registered for the agent's device

#### Scenario: An unclassified inventory keeps the announced MAC
- **GIVEN** an agent on a platform that cannot classify its interfaces
- **WHEN** the agent checks in with `host_macs` and an inventory of unclassified interfaces
- **THEN** core SHALL use `host_macs` as the agent's identity MACs

#### Scenario: Older cores and agents interoperate
- **GIVEN** a hello carrying `host_interfaces`, `host_ip` and `host_macs`
- **WHEN** a gateway or core built before `host_interfaces` decodes it
- **THEN** `host_ip` and `host_macs` SHALL decode unchanged
- **AND** a hello from an agent built before `host_interfaces` SHALL decode with no inventory

### Requirement: Agent Host Links By Shared Eligible MAC
The system SHALL resolve an agent's check-in to an existing device that holds one of the agent's eligible MACs, whatever the device's or the agent's hostname and address.
An eligible MAC on an interface the agent does not announce links as one on the announced
interface does. Records the agent's eligible MACs name together are one host and converge through
the conflict merge under every merge guard. The resolution never uses the hostname, and it uses an
address only for an update with no strong identifier.

#### Scenario: An FQDN agent links through a NIC it does not announce
- **GIVEN** a device known by discovery at address A, holding MAC M2
- **AND** an agent with an FQDN hostname announcing address B on a NIC with MAC M1, and reporting a second NIC with permanent MAC M2 at address A
- **WHEN** the agent checks in
- **THEN** the agent SHALL resolve to the known device
- **AND** the device SHALL hold the agent id, M1 and M2

#### Scenario: A short-name agent links the same way
- **GIVEN** the same known device
- **WHEN** an agent with the device's short hostname and the same inventory checks in
- **THEN** the agent SHALL resolve to the known device

### Requirement: Same-Named Hosts Without A Shared Strong Identifier Never Fuse
The system SHALL NOT link an agent to, or merge it with, a device with which it shares no strong identifier, even when their hostnames match exactly and an address the agent reports is the device's.
Disjoint eligible MACs mean two devices, regardless of name or address. Such an agent gets a
device of its own; the other device keeps every identifier it holds, and the agent's device takes
none of them.

#### Scenario: Two sites with identical node names
- **GIVEN** a device at site A named `node01`, at address A, holding MAC MA
- **AND** an agent at site B named `node01.site-b.example.com` whose NICs carry MACs MB1 and MB2, one of them at address A
- **WHEN** the agent checks in
- **THEN** the agent SHALL get a device of its own holding the agent id, MB1 and MB2
- **AND** the site A device SHALL still hold only MA

#### Scenario: An agent sharing nothing with a hypervisor record
- **GIVEN** a hypervisor node record holding only its integration id, with a confirmed alias of the agent's address
- **WHEN** the node's agent checks in reporting MACs the record does not hold
- **THEN** the agent SHALL get a device of its own
- **AND** the node record SHALL keep its integration id, and the agent's device SHALL NOT hold it
- **AND** the node record's alias of the agent's address SHALL be invalidated and recorded as an `alias_invalidated` decision

### Requirement: Agent Address And Hostname Corroboration Is Review Evidence
The system SHALL record, and SHALL NOT act on, agreement between an agent and another device that shares no eligible MAC with it: an address the agent reports held by that device together with an equal first hostname label.
The record is a `policy_block` identity decision with reason `agent_corroboration_not_identity`
naming both devices, the address and the label, which opens a de-duplication task. A failed read
records nothing and never fails the check-in.

#### Scenario: Agreement opens review, not a merge
- **GIVEN** a device named `node01` at address A
- **AND** an agent named `node01.site-a.example.com` that reports address A on one of its NICs and shares no eligible MAC with the device
- **WHEN** the agent checks in
- **THEN** a `policy_block` decision with reason `agent_corroboration_not_identity` SHALL name both devices
- **AND** the devices SHALL NOT be merged

### Requirement: Agent Identity May Join A Source-Authoritative Record
The system SHALL let an agent's eligible MACs link it to, and merge it with, a record that holds or held a source-authoritative identifier, and the value pushed northbound for that identifier SHALL follow the merged device.
This is the user's decision of 2026-10-28: an Armis record and what an agent learns about the
same endpoint describe one device. An update that itself carries a source-authoritative
identifier is still refused a record holding a different one, and two records holding different
identifiers of one source still never merge. When an agent links onto an Armis record, a
`legacy`-semantics source pushes the agent's check-in availability, and a `merged`-semantics
source pushes the availability the agent's self-report resolves. When the agent's device and an
Armis record merge, the device holding the agent id survives and the Armis id, its archived rows
and its source observations move to it.

#### Scenario: An agent links onto an Armis endpoint
- **GIVEN** an endpoint Armis reports down, whose record holds a MAC discovery registered
- **WHEN** an agent on the endpoint checks in reporting that MAC as a NIC's permanent MAC
- **THEN** the agent SHALL resolve to the Armis record
- **AND** a `legacy`-semantics source SHALL push the endpoint available
- **AND** a `merged`-semantics source SHALL push the endpoint available

#### Scenario: An Armis record merges into the agent's device
- **GIVEN** an agent's device and an Armis record holding a MAC the agent's host carries
- **WHEN** the agent checks in reporting that MAC
- **THEN** the Armis record SHALL be merged into the agent's device
- **AND** the agent's device SHALL hold the Armis id
- **AND** the source's population SHALL push the Armis id from the agent's device
