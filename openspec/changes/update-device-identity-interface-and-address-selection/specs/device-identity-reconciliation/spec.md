# device-identity-reconciliation Specification

## ADDED Requirements

### Requirement: Interface MACs Identify Their Own Device

MAC addresses discovered on a device's OWN interfaces SHALL be registered as strong identifiers of
that device, so that a multi-interface chassis is identified by every NIC it owns.

This SHALL apply only to MACs read from the device's own interface table. MACs observed on the wire
— neighbour ARP/NDP entries, forwarding tables, and any other record of what a device can SEE —
SHALL NOT be registered as identifiers of the observing device.

Existing MAC eligibility rules apply unchanged: a locally-administered or randomized MAC SHALL NOT
anchor a device, and the polling-agent exclusion SHALL continue to apply.

No new merge rule is introduced. Once a device carries its interface MACs, the scheduled duplicate
reconciliation merges duplicates by the existing shared-strong-identifier rule.

#### Scenario: A router's second interface is not a second device

- **GIVEN** a chassis whose interface table reports `eth9` with MAC `f4:92:bf:75:c7:2a` and `eth10`
  with MAC `f4:92:bf:75:c7:2b`
- **AND** a separate device row already exists carrying `f4:92:bf:75:c7:2b`
- **WHEN** the interface MACs are registered on the chassis device
- **THEN** the chassis device SHALL carry `f4:92:bf:75:c7:2b` as a strong identifier
- **AND** the two rows SHALL share a strong identifier
- **AND** the scheduled duplicate reconciliation SHALL merge them by the existing rule

#### Scenario: A neighbour's MAC never identifies the observer

- **GIVEN** a router whose neighbour table lists MACs of hosts on its segments
- **WHEN** those neighbour entries are ingested
- **THEN** none of those MACs SHALL be registered as an identifier of the router

#### Scenario: A locally-administered interface MAC does not anchor

- **GIVEN** an interface whose reported MAC is locally administered
- **WHEN** interface MACs are registered
- **THEN** that MAC SHALL NOT be registered as an anchoring identifier

### Requirement: Interface Address Binding

An address learned for a specific interface SHALL be recorded against that interface, not only
against the device. An interface that holds an address SHALL NOT be stored with an empty address
set when that address is known.

#### Scenario: A gateway address is bound to the interface that holds it

- **GIVEN** an SNMP walk reports that interface `eth10` holds `192.168.1.1`
- **WHEN** the walk result is ingested
- **THEN** `192.168.1.1` SHALL be recorded on `eth10`
- **AND** `eth10` SHALL NOT be stored with an empty address set

## MODIFIED Requirements

### Requirement: IP Alias Sightings and Promotion

A device's primary address SHALL be chosen by routability, not by arrival order. A routable address
SHALL outrank a Unique Local Address, which SHALL outrank a link-local address. A loopback address
SHALL NEVER be selected as a primary address.

Where a device's primary address is link-local or ULA and the device already holds a routable
address as an alias, that routable address SHALL be promoted to primary. Promotion SHALL NOT create
a device and SHALL NOT alter which device an address resolves to.

Where a device holds no routable address, it SHALL retain its current primary address rather than
being left without one. Link-local and ULA addresses SHALL continue to be recorded as aliases and
remain valid sighting evidence; only the choice of primary address changes.

#### Scenario: A routable alias is promoted over a link-local primary

- **GIVEN** a device whose primary IP is `fe80::f692:bfff:fe75:c72b`
- **AND** which holds `192.168.1.1` as a confirmed alias
- **WHEN** primary-address selection runs
- **THEN** the device's primary IP SHALL become `192.168.1.1`

#### Scenario: A device with only a link-local address keeps it

- **GIVEN** a device whose only known address is link-local
- **WHEN** primary-address selection runs
- **THEN** the device SHALL retain that address as its primary
- **AND** its primary address SHALL NOT be emptied

#### Scenario: Loopback is never primary

- **GIVEN** a device reporting `127.0.0.1` among its addresses
- **WHEN** primary-address selection runs
- **THEN** `127.0.0.1` SHALL NOT be selected as the primary address
