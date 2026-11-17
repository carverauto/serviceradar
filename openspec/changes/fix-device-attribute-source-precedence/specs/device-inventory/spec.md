## ADDED Requirements

### Requirement: Weaker evidence does not overwrite stronger device attributes
Sync ingestion SHALL NOT replace a stored device name or vendor with a value
derived from weaker evidence. A name derived from the device's address because
the update carries no hostname, and a vendor derived from the MAC address's
IEEE OUI registrant, SHALL only fill an empty attribute or replace a value of
the same weak kind. The same rule SHALL apply when two updates for one device
are merged inside one ingestion batch.

#### Scenario: A hostname-less observation keeps the observed name
- **GIVEN** a device whose name was recorded from an SNMP sysName
- **WHEN** a passive observation with the device's IP and MAC but no hostname is ingested
- **THEN** the device name SHALL remain the sysName

#### Scenario: A placeholder name follows an address change
- **GIVEN** a device with no hostname whose name is its address
- **WHEN** an update without a hostname moves the device to a new address
- **THEN** the device name SHALL become the new address

#### Scenario: An OUI vendor does not replace a reported vendor
- **GIVEN** a device whose vendor was inferred from SNMP device evidence
- **WHEN** an update whose only vendor evidence is the MAC OUI is ingested
- **THEN** the stored vendor and its provenance SHALL be unchanged

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
