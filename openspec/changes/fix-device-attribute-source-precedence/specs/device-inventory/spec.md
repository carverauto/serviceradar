## ADDED Requirements

### Requirement: Weaker evidence does not overwrite stronger device attributes
Sync ingestion SHALL record, alongside each stored device name, vendor, type
and integration type, the source and evidence strength of the value. An
equal-or-stronger write SHALL replace the recorded value, and a weaker write
SHALL only fill an attribute that has no stored value. A populated value
without a recorded strength (written before this rule) SHALL be kept against a
write of the weakest tier; the next write of any higher tier SHALL replace it
and record its strength.

Name strength, weakest first, with no two sources sharing a tier: a name
derived from an address because the update carries no hostname (as sent by the
passive census, which re-emits every binding seen in the last 15 minutes every
120 seconds, and by hypervisor enrichment of existing devices); a hostname from
a passive census sighting; a name reported by an automation inventory (such as
AWX); an SNMP sysName; a name reported by the hypervisor platform inventory. A
name derived from an address SHALL use the address the device keeps after the
address rank guard. The hostname SHALL be gated by the same tiers and SHALL be
accepted or rejected together with the name as one value.

Vendor strength, weakest first: a name that names SNMP agent software (such as
Net-SNMP), from device, integration or metadata evidence; the IEEE OUI
registrant of the MAC address (recorded with mac_vendor_source ieee_oui),
always this middle tier whatever the registrant string; a hardware vendor name
from device, integration or metadata evidence (a sysObjectID hardware
enterprise, sysDescr inference, a classification rule, an integration report,
or explicit metadata). For a value that is not an OUI lookup, the name, not
the channel or the sysObjectID enterprise alone, decides whether it is agent
software, a hardware vendor, or not a vendor: a sysObjectID under enterprise
8072 with a hardware vendor from sysDescr or a classification rule ranks in
the strongest tier. An OS, software or platform name (such as Linux,
Microsoft, NGINX, or an automation platform's own product name) is not vendor
evidence and SHALL NOT be written to the vendor, from any source; it is
ignored for the vendor (an OS or software name goes to the OS / software
fields) while the same update's OUI or hardware vendor is still ranked.

Type strength, weakest first: a generic type set without device evidence (such
as host from an automation inventory); a type inferred from a passive
fingerprint or classification rule; a type derived from SNMP (such as Router
from ip_forwarding); a type reported by the inventory that owns the device's
platform role (such as Hypervisor from the hypervisor inventory). Type and
type_id SHALL be accepted or rejected together as one value. Manual type
ownership SHALL keep precedence over both. Integration type strength, weakest
first: a generic automation inventory; the inventory that discovers the device
as its own platform object.

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

#### Scenario: A hypervisor-enrichment update without a hostname keeps the node name
- **GIVEN** a hypervisor node whose name hv-node-01 was recorded from the automation inventory
- **WHEN** a hypervisor-enrichment update for the node at 192.0.2.30 with no hostname is ingested
- **THEN** the device name SHALL remain hv-node-01

#### Scenario: A rejected address does not rename the device
- **GIVEN** a device with no hostname at 192.0.2.20 whose name is its address
- **WHEN** a hostname-less update reports a link-local address that the address rank guard rejects
- **THEN** the device address SHALL remain 192.0.2.20
- **AND** the device name SHALL remain 192.0.2.20

#### Scenario: A link-local sighting never replaces a name
- **GIVEN** a device at 2001:db8::20 whose name ap-01 was recorded from an SNMP sysName
- **WHEN** an NDP sighting of fe80::20 with no hostname is ingested for the device
- **THEN** the device name SHALL remain ap-01

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

#### Scenario: A metadata agent-software vendor does not outrank the OUI vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** an update whose explicit metadata vendor is Net-SNMP is ingested
- **THEN** the stored vendor SHALL remain the OUI vendor

#### Scenario: A metadata hardware vendor outranks the OUI vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** an update whose explicit metadata vendor is a hardware vendor is ingested
- **THEN** the stored vendor SHALL become that hardware vendor

#### Scenario: A fingerprint classification naming an OS does not change the vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** a passive fingerprint update whose classification names an operating system such as Linux is ingested
- **THEN** the stored vendor SHALL be unchanged
- **AND** the operating system SHALL be recorded in the OS field, not the vendor

#### Scenario: An OS classification does not suppress the OUI vendor
- **GIVEN** a device with no stored vendor
- **WHEN** a passive census update whose fingerprint classification names Linux and whose MAC OUI registrant is Example NIC Vendor is ingested
- **THEN** the stored vendor SHALL become Example NIC Vendor
- **AND** Linux SHALL be recorded in the OS field

#### Scenario: An OUI registrant string stays in the OUI tier
- **GIVEN** a device whose vendor Ubiquiti was derived from a sysObjectID hardware enterprise and recorded as the strongest tier
- **WHEN** a passive census update whose MAC OUI registrant is Ubiquiti Inc is ingested
- **THEN** the stored vendor SHALL remain Ubiquiti

#### Scenario: An integration's own platform name is not a device vendor
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** an automation inventory update that reports its own platform product name as the vendor is ingested
- **THEN** the stored vendor SHALL be unchanged

#### Scenario: Automation inventory does not replace hypervisor type and integration type
- **GIVEN** a hypervisor node whose type Hypervisor and integration type hypervisor were recorded from the hypervisor inventory
- **WHEN** an automation inventory update reporting the node as a generic host is ingested
- **THEN** the device type SHALL remain Hypervisor
- **AND** the device integration type SHALL remain hypervisor

#### Scenario: A routing hypervisor node keeps its platform type
- **GIVEN** a hypervisor node whose type Hypervisor was recorded from the hypervisor inventory
- **WHEN** a mapper update reports ip_forwarding enabled for the node
- **THEN** the device type SHALL remain Hypervisor
- **AND** the device type_id SHALL remain the Hypervisor type_id

#### Scenario: A hypervisor node settles on its platform inventory name
- **GIVEN** a hypervisor node reported by an automation inventory as hv-node-01, by the mapper with sysName pve-a, and by the hypervisor inventory as pve-node-a
- **WHEN** automation-inventory, mapper and hypervisor-inventory writes alternate, in one batch in either order or across batches
- **THEN** the device name and hostname SHALL both be pve-node-a
- **AND** the Proxmox plugin assignment inputs SHALL NOT change

#### Scenario: Alternating sources leave the agent config unchanged
- **GIVEN** an agent whose SNMP targets and plugin assignments are selected and named from device attributes
- **AND** the name, hostname, vendor, type and integration type of those devices already have recorded strengths
- **WHEN** mapper passes, passive census passes, automation-inventory cycles and hypervisor-enrichment cycles alternate with no change on the network
- **THEN** the compiled agent config version SHALL NOT change

### Requirement: Integration identifiers are kept per integration
A device observed by more than one integration SHALL keep each integration's
identifier separately in its provider-scoped identifiers, and a write by one
integration SHALL NOT replace the identifier recorded by another. Device
metadata SHALL NOT hold a single last-writer-wins integration identifier.

#### Scenario: Two inventory integrations describe one node
- **GIVEN** a hypervisor node reported by both an automation inventory and the hypervisor inventory
- **WHEN** both integrations run repeatedly
- **THEN** each integration's identifier SHALL remain stable

### Requirement: Plugin inputs carry only identifiers the plugin's provider owns
A device-backed plugin input item SHALL carry an integration identifier only
for the plugin whose provider owns that identifier. Proxmox plugin inputs SHALL
read the hypervisor provider reference from the provider-scoped identifiers,
which only the hypervisor inventory writes.

#### Scenario: Alternating inventory writes leave Proxmox plugin inputs unchanged
- **GIVEN** a policy-generated Proxmox plugin assignment over hypervisor nodes
- **WHEN** automation-inventory and hypervisor-enrichment writes for those nodes alternate
- **THEN** the Proxmox plugin assignment inputs SHALL NOT change

#### Scenario: Plugins that do not own an identifier do not receive it
- **GIVEN** a device-backed plugin whose provider is not the hypervisor inventory
- **WHEN** its input items are built for a hypervisor node
- **THEN** the items SHALL NOT include the hypervisor integration identifier
