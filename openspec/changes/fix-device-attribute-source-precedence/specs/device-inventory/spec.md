## ADDED Requirements

### Requirement: Weaker evidence does not overwrite stronger device attributes
Sync ingestion SHALL record, alongside each stored device name, vendor, type,
integration type and management_device_id, the source and evidence strength of
the value, so that a recorded clear is distinguishable from an unset value. A write
SHALL replace the recorded value when its strength is strictly greater, or when
its strength is equal and it comes from the same source that recorded the
stored value; a write from a different source at the same tier SHALL keep the
stored value until a strictly stronger write arrives. A weaker write SHALL only
fill an attribute for which no strength has been recorded; a recorded clear
(an empty value with a recorded strength, such as a platform inventory's
cleared management_device_id) is a stored decision and SHALL NOT be filled by
a weaker write. A populated value
without a recorded strength (written before this rule) SHALL be kept against a
write of the weakest tier; the next write of any higher tier SHALL replace it
and record its strength. For a value made of several fields (name and
hostname; vendor and model; type, type_id and device_role) the strength
decision SHALL accept or reject the write as a whole, and a field of that value
that the write does not carry SHALL stay stored and SHALL NOT be cleared by the
write.

Any integration inventory that reports a device's identity SHALL be platform
inventory for the fields it reports, unless this requirement ranks it
otherwise: its name and hostname take the strongest name tier, its vendor and
model the hardware-vendor tier, its type, type_id and device_role the
platform-inventory type tier, and its management_device_id the platform tier
above the mapper. The automation inventory (such as AWX) is ranked below that,
as stated in each ladder. Every writer of these fields, including hypervisor
enrichment, Proxmox enrichment, camera inventory, WiFi-map ingestion, endpoint
inventory, SHALL write them through the same strength decision, with no update
path that bypasses it. The agent gateway check-in's hostname and type are
corroboration, not identity: it SHALL NOT write name, hostname, type, type_id or
device_role. A defaulted or guessed vendor (such as a filler vendor an
ingestor sets when its source row has none) is not vendor evidence and SHALL
NOT be written to the vendor.

Name strength, weakest first (several sources may share a tier, and the
same-source rule above decides between them): a name
derived from an address because the update carries no hostname (as sent by the
passive census, which re-emits every binding seen in the last 15 minutes every
120 seconds, and by hypervisor enrichment of existing devices); a hostname from
a passive census sighting; a name reported by an automation inventory (such as
AWX); an SNMP sysName; a name reported by a platform inventory (such as the
hypervisor or camera inventory). A
name derived from an address SHALL use the address the device keeps after the
address rank guard, and only when that address is not link-local; an
address-fallback write SHALL carry that address in both the name and the
hostname, so the same source rewriting its own value moves the pair together. A
link-local primary SHALL NOT become the name or hostname: the device keeps a
stronger recorded name, or none. The hostname SHALL be gated by the same tiers and SHALL be
accepted or rejected together with the name as one value. Every
hypervisor-enrichment update for a host or guest, both the repeating update for
an existing device and the placeholder update that creates one, SHALL carry the
inventory record's name as the strongest-tier name and hostname pair when the
record has one; a provider reference or an address is never that name, and an
update with no record name stays an address fallback (none when the kept
address is link-local).

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
evidence and SHALL NOT be written to the vendor, from any source, and a write
whose vendor is not vendor evidence SHALL NOT write the model either; it is
ignored for the vendor (an OS or software name goes to the OS / software
fields) while the same update's OUI or hardware vendor is still ranked. The
model SHALL be accepted or rejected together with the vendor as one value, at
the vendor's write strength.

Type strength, weakest first: a generic type set without device evidence (such
as host from an automation inventory); a type inferred from a passive
fingerprint or classification rule; a type derived from SNMP (such as Router
from ip_forwarding); a type reported by the inventory that owns the device's
platform role (such as Hypervisor from the hypervisor inventory, or a camera
type from the camera inventory). Type,
type_id and the metadata device_role SHALL be accepted or rejected together as
one value on this ladder: a platform-inventory role (hypervisor, virtual-guest)
outranks an SNMP / mapper role (router, ap_bridge, switch_l2, host), which
outranks a fingerprint role, which outranks a generic host. A mapper role
SHALL NOT replace a hypervisor or virtual-guest role. Manual type ownership
SHALL keep precedence over all three fields. Integration type strength, weakest
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
- **THEN** the stored vendor and model SHALL be unchanged
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

#### Scenario: A platform product name does not write the model either
- **GIVEN** a hypervisor node whose vendor and model were recorded from SNMP hardware evidence
- **WHEN** a hypervisor discovery update reporting the platform product name Proxmox as vendor and PVE as model is ingested
- **THEN** the stored vendor and model SHALL be unchanged

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

#### Scenario: A hypervisor node scored as a host keeps its platform role
- **GIVEN** a hypervisor node whose type and device_role hypervisor were recorded from the hypervisor inventory
- **WHEN** a mapper pass scores the node's role as host
- **THEN** the device_role SHALL remain hypervisor
- **AND** the node's plugin input item SHALL keep target_kind pve_host
- **AND** the Proxmox plugin assignment inputs SHALL NOT change

#### Scenario: A hypervisor placeholder without a record name is an address fallback
- **GIVEN** a hypervisor inventory record with a provider reference and the address 192.0.2.40 but no name
- **WHEN** the placeholder update that creates its device is ingested
- **THEN** the device name and hostname SHALL be recorded as the address fallback 192.0.2.40, not the provider reference
- **AND** a later SNMP sysName SHALL replace them

#### Scenario: A hypervisor node settles on its platform inventory name
- **GIVEN** a hypervisor node reported by an automation inventory as hv-node-01, by the mapper with sysName pve-a, and by the hypervisor inventory as pve-node-a
- **WHEN** automation-inventory, mapper and hypervisor-inventory writes alternate, in one batch in either order or across batches
- **THEN** the device name and hostname SHALL both be pve-node-a
- **AND** the Proxmox plugin assignment inputs SHALL NOT change

#### Scenario: Alternating sources leave the agent config unchanged
- **GIVEN** an agent whose SNMP targets and plugin assignments are selected and named from device attributes
- **AND** the name, hostname, vendor, model, type, type_id, device_role, integration type and management_device_id (including a recorded clear) of those devices already have recorded strengths
- **WHEN** mapper passes, passive census passes, automation-inventory cycles and hypervisor-enrichment cycles alternate with no change on the network
- **THEN** the compiled agent config version SHALL NOT change

### Requirement: Attributes read by agent configuration have one writer or a rank
Sync ingestion SHALL give every single-valued device attribute read by plugin
input building or agent configuration compilation exactly one owning writer or
a rank by recorded strength. A metadata key with an owning writer SHALL be
replaced only by that owner; any other ingestor MAY fill the key only when it
is absent. The owned keys are hypervisor_provider_ref, proxmox_node,
proxmox_cluster, hypervisor_guest_type, hypervisor_vmid and proxmox_base_url
(owned by the hypervisor platform inventory) and proxmox_candidate,
proxmox_tls_sans_recorded and proxmox_tls_san_ips (owned by the mapper Proxmox
candidate probe). The management_device_id SHALL be ranked with platform
inventory (such as the camera inventory) above the mapper. A platform
inventory's value, including a clear to none, SHALL be the stronger value: a
mapper write SHALL NOT replace it, and the mapper's fill of an empty
management_device_id SHALL NOT put a parent back on a device whose platform
inventory cleared it.

#### Scenario: A non-owner does not overwrite an owned metadata key
- **GIVEN** a hypervisor node whose proxmox_node pve-a was written by the hypervisor inventory
- **WHEN** an automation inventory update carrying proxmox_node pve-b is ingested
- **THEN** proxmox_node SHALL remain pve-a

#### Scenario: A non-owner fills an absent metadata key
- **GIVEN** a device with no proxmox_node
- **WHEN** an automation inventory update carrying proxmox_node pve-b is ingested
- **THEN** proxmox_node SHALL become pve-b

#### Scenario: The mapper does not replace a camera-inventory management device
- **GIVEN** a camera whose management_device_id was written by the camera inventory
- **WHEN** a mapper update carrying a different management_device_id is ingested
- **THEN** the management_device_id SHALL be unchanged

#### Scenario: The mapper does not refill a management device the camera inventory cleared
- **GIVEN** a camera whose management_device_id the camera inventory cleared to none
- **WHEN** a mapper pass that would fill an empty management_device_id runs
- **THEN** the management_device_id SHALL remain none
- **AND** the SNMP polling host compiled for the camera SHALL NOT change

#### Scenario: Two writers at the same tier keep the first recorded value
- **GIVEN** a camera whose vendor Example Cam Co and model were recorded from the camera inventory at the hardware-vendor tier
- **WHEN** a mapper update deriving the hardware vendor Example Cam at the same tier is ingested
- **THEN** the stored vendor and model SHALL remain the camera inventory values
- **AND WHEN** the camera inventory reports the same camera again
- **THEN** its write SHALL be accepted as the same source

#### Scenario: An agent check-in does not change a guest's identity
- **GIVEN** a virtual guest whose name, hostname, type Virtual and device_role virtual-guest were recorded from the hypervisor inventory
- **WHEN** an agent gateway check-in reporting hostname guest-host-01 and type Server for that guest is ingested
- **THEN** the guest name, hostname, type, type_id and device_role SHALL be unchanged

#### Scenario: A defaulted vendor is not written
- **GIVEN** a device whose vendor was recorded from the MAC OUI
- **WHEN** a WiFi-map batch row with no vendor is ingested and the ingestor supplies a default vendor
- **THEN** the stored vendor SHALL be unchanged

#### Scenario: An SNMP-polled camera keeps its camera inventory identity
- **GIVEN** a camera whose name, vendor, model, type and management_device_id (including a recorded clear) were recorded from the camera inventory
- **AND** the camera is also polled by SNMP and seen by the passive census
- **WHEN** mapper passes and passive census passes alternate with camera inventory passes
- **THEN** the camera name, vendor, model, type and management_device_id SHALL stay at the camera inventory values
- **AND** the compiled agent config version SHALL NOT change

#### Scenario: A role-only write keeps the stored type
- **GIVEN** a device whose type, type_id and device_role were recorded at the SNMP tier
- **WHEN** an equal-strength mapper write carrying only device_role is accepted
- **THEN** the device_role SHALL be updated
- **AND** the stored type and type_id SHALL remain

### Requirement: A device with a usable IPv4 keeps an IPv4 primary address
Sync ingestion SHALL treat as a routable address an address the primary-IP
chooser accepts that is not link-local, not a directed broadcast (as
AliasPolicy's alias predicate decides with the device's known interface CIDRs)
and not host-internal; a ULA (sr_address_rank 30) is routable. A usable IPv4 is
a routable IPv4 (sr_address_rank 40 or higher). An IPv6-only device is one with
no usable IPv4; a link-local IPv4 (169.254/16) does not count. Within a family
the never-downgrade rank still holds, so a link-local never replaces a ULA or
anything stronger. Sync ingestion SHALL
keep a usable IPv4 as the primary ip of every device that has one; no IPv6 SHALL
become primary on such a device, and
every aliasable IPv6 (global or ULA) SHALL be recorded as an alias. The
preference SHALL rank only addresses a chooser already accepts as a primary
and SHALL NOT promote an address a chooser rejects, such as a host-internal
bridge address a guest chooser skips. A link-local address (fe80::/10 or
169.254/16) SHALL NOT become an alias or the name or hostname, and SHALL NOT be
the primary ip of a device that has any routable address. A device whose only
address is link-local SHALL keep that link-local as its primary ip under the
never-downgrade rank, with no address-fallback name (it keeps a stronger
recorded name, or none), and any routable address (a usable IPv4, or a
global or ULA IPv6 when no usable IPv4 exists) SHALL replace it. An IPv6 SHALL be primary only on an IPv6-only device,
and a usable IPv4 that device later gains SHALL take over. A change between two
usable IPv4s SHALL replace the primary, and the never-downgrade address rank
SHALL still apply within a family. Every primary-IP chooser SHALL follow this
rule, including the upsert guard, the Elixir address ranking, hypervisor guest
primary-IP selection, hypervisor host primary-IP selection, the discovery
ingestor's guest address fallback, the Proxmox plugin's guest primary-IP
selection, the Armis sync source's address walk (over the union of its split
IPAddress, IPv4Addresses and IPv6Addresses, skipping blacklisted addresses:
usable IPv4 first, then non-link-local IPv6, then a link-local only if nothing
else), the NetBox plugin's primary-IP selection (which already prefers the
IPv4), and the camera path: each SHALL submit a chooser-accepted IPv4 over any
IPv6 among every address on the host or guest when one exists, keeping its own
order among accepted IPv4s, and SHALL NOT submit a link-local address as
primary when a routable address exists. The succession address hand-over
compares only the successor's stored ip with the survivor's: it SHALL NOT
replace a usable IPv4 with an IPv6, SHALL NOT replace a routable address with a
link-local, and MAY take a link-local only when the survivor has no routable
address, so a link-local-only device keeps its only address. The
address-fallback name SHALL follow the primary ip except that it SHALL NOT be a
link-local; when the device has a usable IPv4 the name and hostname SHALL NOT
take an IPv6 literal, and an IPv6-only device's fallback name MAY be its
routable IPv6.

#### Scenario: A dual-stack census sighting keeps the IPv4 primary
- **GIVEN** a device whose primary ip is 192.0.2.3
- **WHEN** the passive census sights it by NDP as 2001:db8::3
- **THEN** the primary ip SHALL remain 192.0.2.3
- **AND** 2001:db8::3 SHALL be recorded as a live alias of the device
- **AND** the device name and hostname SHALL NOT be an IPv6 literal

#### Scenario: A link-local sighting is not identity
- **GIVEN** a device whose primary ip is 192.0.2.3
- **WHEN** the passive census sights it by NDP as fe80::3
- **THEN** fe80::3 SHALL NOT be recorded as an alias, the primary ip or the name

#### Scenario: A link-local-only device keeps its link-local primary
- **GIVEN** a device whose only reported address is fe80::9
- **WHEN** it is ingested
- **THEN** the primary ip SHALL be fe80::9
- **AND** fe80::9 SHALL NOT be recorded as an alias, the name or the hostname
- **AND WHEN** the device is later sighted at 192.0.2.9
- **THEN** the primary ip SHALL become 192.0.2.9

#### Scenario: A rejected host-internal address never becomes primary
- **GIVEN** a guest whose chooser-accepted primary is 192.0.2.8 and which also reports the host-internal address 172.17.0.1 on docker0 that the guest chooser skips
- **WHEN** the guest's primary ip is chosen
- **THEN** the primary ip SHALL remain 192.0.2.8
- **AND** 172.17.0.1 SHALL NOT be recorded as an alias of the guest

#### Scenario: An IPv6-only device that gains an IPv4 switches primary
- **GIVEN** an IPv6-only device whose primary ip is 2001:db8::5
- **WHEN** a sighting reports the device at 192.0.2.5
- **THEN** the primary ip SHALL become 192.0.2.5
- **AND** 2001:db8::5 SHALL remain a live alias

#### Scenario: An IPv4 re-IP still replaces the primary
- **GIVEN** a device whose primary ip is 192.0.2.6
- **WHEN** the device is confirmed at 198.51.100.6 instead
- **THEN** the primary ip SHALL become 198.51.100.6

### Requirement: Each address has one live holder and own addresses stay live aliases
Sync ingestion SHALL keep every aliasable address a device owns, in both
families, as a live alias of that device, including an address displaced from
primary or never promoted. An address is aliasable when AliasPolicy's alias
predicate, called with the device's known interface CIDRs, accepts it (which,
among others, admits global, private and ULA addresses and rejects link-local
addresses and directed broadcasts, including a bare 192.0.2.255 on a known
192.0.2.0/24 interface) and it is
not host-internal (an address a primary-IP chooser skips as host-internal, such
as a container bridge, or a shared interface address kept off the ip merge
type). A link-local, directed-broadcast or host-internal address SHALL NOT be
an alias; a directed-broadcast or host-internal address SHALL NOT be the
primary ip, and a link-local SHALL NOT be the primary ip of a device that has
any routable address. An address SHALL have one live holder per partition: a
confirmed re-attribution of an address to another device SHALL expire the
previous holder's alias for it in the same write, and a holder that has not
re-sighted an address within the alias expiry window SHALL be expired. Sweep
target attribution SHALL read only the current live holder.

#### Scenario: Sweep targets are stable for an unchanged inventory
- **GIVEN** an agent whose sweep targets come from device addresses and aliases
- **WHEN** the sweep configuration is compiled twice with no inventory change between
- **THEN** both compiles SHALL produce identical sweep targets with identical device_uid attribution

#### Scenario: A stale cross-device alias is expired on re-attribution
- **GIVEN** an address 192.0.2.7 recorded as a live alias of device A
- **WHEN** 192.0.2.7 is confirmed as belonging to device B
- **THEN** device A's alias for 192.0.2.7 SHALL be expired in the same write
- **AND** the sweep target for 192.0.2.7 SHALL be attributed to device B

#### Scenario: A dual-stack device is swept in both families
- **GIVEN** a device with primary ip 192.0.2.3 and alias 2001:db8::3
- **WHEN** the sweep configuration is compiled
- **THEN** both 192.0.2.3 and 2001:db8::3 SHALL be sweep targets attributed to that device

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
