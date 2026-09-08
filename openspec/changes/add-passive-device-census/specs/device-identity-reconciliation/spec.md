## ADDED Requirements

### Requirement: Randomized MAC addresses are classified and never treated as hardware identity
Device identity SHALL detect a locally administered MAC address and SHALL NOT use it to anchor a canonical device, merge two devices, or claim an IP.
Modern iOS and Android rotate their MAC per SSID and re-randomize over time. Identity
reconciliation treats a distinct MAC as distinct hardware, so a passive census that feeds it
randomized MACs manufactures a new device on every rotation — at far higher volume than a
sweep, and with the same downstream symptoms as anchorless devices squatting IPs.

Detection is deterministic and needs no heuristics: bit 1 of the first octet marks a locally
administered address, which every randomizing implementation sets. In practice the first octet
ends in `2`, `6`, `A`, or `E`.

#### Scenario: A randomized MAC does not create a canonical device
- **GIVEN** a passive observation carries a locally administered MAC
- **WHEN** identity reconciliation processes it
- **THEN** the MAC SHALL be marked as randomized
- **AND** it SHALL NOT anchor a new canonical device on its own

#### Scenario: A rotating phone does not multiply into many devices
- **GIVEN** the same physical phone is observed under three different randomized MACs
- **WHEN** each observation is reconciled
- **THEN** the three MACs SHALL NOT be presented as three distinct hardware devices

#### Scenario: A globally administered MAC keeps its current strength
- **GIVEN** an observation carries a universally administered (burned-in) MAC
- **WHEN** identity reconciliation processes it
- **THEN** it SHALL retain its existing weight as a hardware identifier
- **AND** this requirement SHALL NOT weaken identity for such devices

#### Scenario: A randomized MAC never merges two known devices
- **GIVEN** two existing canonical devices
- **WHEN** a randomized MAC is observed that would otherwise correlate them
- **THEN** the devices SHALL NOT be merged on that evidence

### Requirement: Passive observation is a weak identity signal
A passive device observation SHALL enrich device presence and attributes, and SHALL NOT by itself create a canonical device or claim an IP address.
Passive observation sees whatever is on the wire, including spoofed, transient, and
foreign-segment traffic. It is excellent evidence that *something* was present and poor
evidence of *what* it durably is.

#### Scenario: Presence is recorded without minting a device
- **GIVEN** a passive observation for an IP that matches no known device
- **WHEN** it is ingested
- **THEN** the observation SHALL be retained and queryable
- **AND** it SHALL NOT by itself produce a canonical device claiming that IP

#### Scenario: A known device gains presence and attributes
- **GIVEN** a passive observation correlates to an existing canonical device
- **WHEN** it is ingested
- **THEN** the device's last-seen time SHALL be updated
- **AND** hostname or vendor MAY be enriched when absent or lower-confidence
- **AND** the passive source SHALL be recorded among the device's discovery sources
