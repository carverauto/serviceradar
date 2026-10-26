## MODIFIED Requirements

### Requirement: Hostname Agreement Is Not Identity
The system SHALL NOT merge two existing devices because their hostnames agree, and SHALL NOT adopt an address holder on hostname agreement when either side holds a source-authoritative identifier.
Hostname agreement at an address may still let a record that is not yet a device adopt the
address holder, when neither side holds a source-authoritative identifier, their hardware
serials and partitions are compatible, and no third device claims either identity. When the
hostnames agree and adoption is refused, the record is written as its own device and the pair is
recorded as a `policy_block` identity decision with reason `hostname_agreement_not_identity`,
which opens a de-duplication task.

For an AWX inventory host, host-name agreement SHALL count only as corroboration of an exact
match between the host's `ansible_host` address and the address of the live device that holds
it. Host names agree when their first DNS labels are equal ignoring case, both are non-empty and
neither is an address. With that corroboration the AWX record SHALL merge into the device that
holds the address, and that device SHALL survive. Host-name agreement alone SHALL NOT identify an
AWX host: an AWX host SHALL NOT merge into a device at a different address because the names
agree, and an address match without host-name agreement SHALL NOT merge into an agent-managed
device or a device that carries a MAC unless a Proxmox guest link or an overlapping MAC
corroborates it. A MAC on the AWX host that contradicts the device's MACs SHALL refuse the merge
whatever else agrees.

#### Scenario: Two existing devices with the same hostname stay separate
- **GIVEN** two live devices whose hostnames agree, neither of them an AWX inventory host record
- **WHEN** an update for one of them reports the address the other holds
- **THEN** the devices SHALL NOT be merged
- **AND** a `policy_block` identity decision SHALL name both devices

#### Scenario: A source-authoritative holder is not adopted on hostname agreement
- **GIVEN** a device holding an Armis device id at address A
- **WHEN** a NetBox record with the same hostname and address A arrives
- **THEN** the NetBox record SHALL be written as its own device
- **AND** a `policy_block` identity decision SHALL name both devices

#### Scenario: An AWX host merges on its exact address corroborated by its host name
- **GIVEN** an agent-managed device `host01.example.com` holding address A, and an AWX host `HOST01` with no Proxmox guest link
- **WHEN** the AWX host reports `ansible_host` A
- **THEN** the AWX record SHALL merge into the agent-managed device
- **AND** the agent-managed device SHALL survive the merge

#### Scenario: An AWX host is not merged on its host name alone
- **GIVEN** a device `host01.example.com` holding address A, and an AWX host `host01`
- **WHEN** the AWX host reports `ansible_host` B, a different address
- **THEN** the AWX record SHALL NOT be merged into the device

#### Scenario: An AWX host is not merged on its address under a different host name
- **GIVEN** an agent-managed device `other01.example.com` holding address A, and an AWX host `host01` with no Proxmox guest link
- **WHEN** the AWX host reports `ansible_host` A
- **THEN** the AWX record SHALL NOT be merged into the device

#### Scenario: A MAC contradiction refuses an AWX host's address and host-name match
- **GIVEN** a device `host01` holding address A and MAC M1, and an AWX host `host01` whose variables carry MAC M2
- **WHEN** the AWX host reports `ansible_host` A
- **THEN** the AWX record SHALL NOT be merged into the device
