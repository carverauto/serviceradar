## ADDED Requirements

### Requirement: Weaker evidence does not overwrite stronger device attributes
Sync ingestion SHALL record, alongside each stored device name and vendor, the
source and evidence strength of the value. A write SHALL replace a stored value
only when its strength is equal to or greater than the recorded strength, and a
weaker write SHALL only fill an attribute that has no stored value. A populated
value without a recorded strength (written before this rule) SHALL be kept
against a write of the weakest tier; the next write of any higher tier SHALL
replace it and record its strength.

Name strength, weakest first: a name derived from an address because the update
carries no hostname; a hostname from a passive census sighting; an SNMP
sysName or a name reported by an integration. A name derived from an address
SHALL use the address the device keeps after the address rank guard.

Vendor strength SHALL follow the vendor derived for the update, never the
evidence channel or the sysObjectID enterprise alone. Weakest first: a derived
vendor that names SNMP agent software (such as Net-SNMP), whether it came from
a sysObjectID under an agent-software enterprise (such as enterprise 8072),
sysDescr inference or a classification rule; the IEEE OUI registrant of the
MAC address, or an explicit metadata vendor on an update that is not from an
integration; a derived vendor that names a hardware vendor, whether it came
from a sysObjectID enterprise, sysDescr inference or a classification rule, or
a vendor reported by an integration. A sysObjectID under enterprise 8072 with
a hardware vendor from sysDescr or a classification rule therefore ranks in
the strongest tier, and a sysDescr or classification result that names agent
software ranks in the weakest tier and never replaces a populated value.

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
- **AND** the vendor's strength is recorded as that strongest tier
- **WHEN** an update whose only vendor evidence is the MAC OUI is ingested
- **THEN** the stored vendor and its provenance SHALL be unchanged

#### Scenario: A sysDescr-inferred hardware vendor outranks the OUI vendor
- **GIVEN** a device whose vendor was inferred from sysDescr and names a hardware vendor
- **AND** the vendor's strength is recorded as the strongest tier
- **WHEN** an update whose only vendor evidence is the MAC OUI is ingested
- **THEN** the stored vendor and its provenance SHALL be unchanged

#### Scenario: A generic SNMP agent vendor does not outrank the OUI vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** an SNMP update whose derived vendor names SNMP agent software (such as Net-SNMP) is ingested
- **THEN** the stored vendor SHALL remain the OUI vendor

#### Scenario: A hardware vendor inferred under an agent-software enterprise outranks the OUI vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** an SNMP update whose sysObjectID is under the Net-SNMP enterprise (8072) and whose sysDescr or classification rule yields a hardware vendor is ingested
- **THEN** the stored vendor SHALL become that hardware vendor

#### Scenario: Alternating sources leave the agent config unchanged
- **GIVEN** an agent whose SNMP targets are selected and named from device attributes
- **AND** the name and vendor of those devices already have recorded strengths
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
