## ADDED Requirements

### Requirement: Weaker evidence does not overwrite stronger device attributes
Sync ingestion SHALL record, alongside each stored device name and vendor, the
source and evidence strength of the value. A write SHALL replace a stored value
only when its strength is equal to or greater than the recorded strength, and a
weaker write SHALL only fill an attribute that has no stored value. A stored
value without a recorded strength SHALL count as the weakest.

Name strength, weakest first: a name derived from an address because the update
carries no hostname; a hostname from a passive census sighting; an SNMP
sysName or a name reported by an integration. A name derived from an address
SHALL use the address the device keeps after the address rank guard.

Vendor strength, weakest first: a vendor derived from a sysObjectID under a
generic SNMP agent-software enterprise (such as Net-SNMP, enterprise 8072); the
IEEE OUI registrant of the MAC address; a vendor derived from a sysObjectID
under a hardware vendor's enterprise number, or reported by an integration.

The same rule SHALL apply when two updates for one device are merged inside one
ingestion batch.

#### Scenario: A hostname-less observation keeps the observed name
- **GIVEN** a device whose name was recorded from an SNMP sysName
- **WHEN** a passive observation with the device's IP and MAC but no hostname is ingested
- **THEN** the device name SHALL remain the sysName

#### Scenario: Batch composition does not change the kept name
- **GIVEN** an SNMP sysName update and a hostname-less passive update for one device
- **WHEN** both are ingested in one batch, in either order
- **THEN** the device name SHALL be the sysName

#### Scenario: A rejected address does not rename the device
- **GIVEN** a device with no hostname at 192.0.2.20 whose name is its address
- **WHEN** a hostname-less update reports a link-local address that the address rank guard rejects
- **THEN** the device address SHALL remain 192.0.2.20
- **AND** the device name SHALL remain 192.0.2.20

#### Scenario: A hardware-enterprise sysObjectID vendor outranks the OUI vendor
- **GIVEN** a device whose vendor was derived from a sysObjectID under a hardware vendor's enterprise number
- **WHEN** an update whose only vendor evidence is the MAC OUI is ingested
- **THEN** the stored vendor and its provenance SHALL be unchanged

#### Scenario: A generic SNMP agent vendor does not outrank the OUI vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** an SNMP update whose sysObjectID is under the Net-SNMP enterprise (8072) is ingested
- **THEN** the stored vendor SHALL remain the OUI vendor

#### Scenario: Alternating sources leave the agent config unchanged
- **GIVEN** an agent whose SNMP targets are selected and named from device attributes
- **WHEN** a mapper pass and a passive census pass alternate with no change on the network
- **THEN** the compiled agent config version SHALL NOT change

### Requirement: Integration identifiers are kept per integration
A device observed by more than one integration SHALL keep each integration's
identifier separately, and a write by one integration SHALL NOT replace the
identifier recorded by another.

#### Scenario: Two inventory integrations describe one node
- **GIVEN** a hypervisor node reported by both an automation inventory and the hypervisor inventory
- **WHEN** both integrations run repeatedly
- **THEN** each integration's identifier SHALL remain stable
- **AND** configuration compiled from the hypervisor integration's identifier SHALL NOT change
