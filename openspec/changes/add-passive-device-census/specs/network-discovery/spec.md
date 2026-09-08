## ADDED Requirements

### Requirement: Passive observation captures the sender MAC from the Ethernet header
netprobe SHALL extract the source MAC (`h_source`) from the Ethernet header of every frame it parses and SHALL attach it to the resulting observation.
The MAC is present on every frame on the local segment and requires no additional traffic to
obtain. Today the eBPF path reads only the network layer, so the identity most useful for
correlation is discarded at the first parsing step.

#### Scenario: An observed IPv4 frame yields an IP-to-MAC binding
- **GIVEN** netprobe is attached to an interface on the device's broadcast domain
- **WHEN** it parses a frame carrying IPv4 traffic from that device
- **THEN** the observation SHALL carry both the source IP and the source MAC
- **AND** no additional packet SHALL be emitted to obtain the MAC

#### Scenario: Off-segment traffic is not attributed to the wrong device
- **GIVEN** a frame arrives from a device on a different broadcast domain
- **WHEN** netprobe records the source MAC
- **THEN** that MAC SHALL be recognised as the forwarding router's, not the origin device's
- **AND** the observation SHALL NOT bind that MAC to the origin device's IP

### Requirement: ARP frames are parsed as join-time device observations
netprobe SHALL parse `ETH_P_ARP` (0x0806) frames and SHALL emit a device observation carrying the sender IP and sender MAC.
ARP is the one signal every IPv4 device emits on joining a segment, including devices that
speak no other discoverable protocol. It is what makes the census complete for short-lived
devices that no scheduled sweep will ever see.

#### Scenario: A device present for seconds is still observed
- **GIVEN** a device joins the segment and issues an RFC 5227 probe or gratuitous ARP
- **AND** it leaves before any scheduled sweep runs
- **WHEN** netprobe parses that ARP frame
- **THEN** a device observation SHALL be recorded with its IP and MAC
- **AND** the observation SHALL be recorded without any active probe being sent

#### Scenario: A device that emits nothing but ARP is still counted
- **GIVEN** a device that answers no sweep, announces no mDNS, and takes no DHCP lease
- **WHEN** it ARPs for its gateway
- **THEN** it SHALL appear in the census

### Requirement: DHCP identity fields are retained rather than discarded
The DHCP parser SHALL retain the client hardware address (`chaddr`), the Option 12 hostname, and the Option 60 vendor class string, in addition to the fingerprint axes it already extracts.
`DhcpObservation` currently keeps `option_order`, `parameter_request_list` and a
`vendor_class_present` boolean. The identity payload is parsed past and dropped, which is why
DHCP contributes nothing to the inventory today despite being parsed on every lease.

#### Scenario: A DHCP lease yields hostname and MAC
- **GIVEN** a device requests a DHCP lease on an observed segment
- **WHEN** netprobe parses the DHCP message
- **THEN** the observation SHALL carry the client MAC from `chaddr`
- **AND** the Option 12 hostname when present
- **AND** the Option 60 vendor class string when present, not merely a presence flag

#### Scenario: Existing fingerprint axes are unaffected
- **WHEN** the DHCP parser retains identity fields
- **THEN** `option_order` and `parameter_request_list` SHALL continue to be extracted unchanged

### Requirement: Passive observations reach the device inventory
netprobe SHALL deliver passive device observations to `DeviceSourceObservation` with its own source identity, so the census is queryable alongside every other discovery source.
No netprobe output reaches the inventory today. Without this the census exists only inside the
probe and cannot inform device presence.

#### Scenario: An observation becomes queryable inventory
- **GIVEN** netprobe records an IP-to-MAC binding for a device
- **WHEN** the observation is delivered
- **THEN** a `DeviceSourceObservation` SHALL exist carrying the IP, MAC, and hostname when known
- **AND** it SHALL identify passive observation as its source, distinguishable from sweep results

### Requirement: The census is passive by default
netprobe SHALL NOT emit probe traffic in order to obtain a MAC address, and any active probing SHALL be an explicit operator opt-in that is disabled by default.
Active probing is visible on customer networks and is unreliable for exactly the transient
devices this change targets: a device that has already left will not answer, and the failure
is cached as absence.

#### Scenario: Discovering a device emits no traffic
- **WHEN** netprobe observes and records a previously unseen device
- **THEN** no packet SHALL be transmitted as part of that discovery

#### Scenario: Active probing requires explicit configuration
- **GIVEN** an operator has not enabled active probing
- **WHEN** netprobe cannot determine a device's MAC passively
- **THEN** it SHALL record the observation without the MAC rather than probe for it
