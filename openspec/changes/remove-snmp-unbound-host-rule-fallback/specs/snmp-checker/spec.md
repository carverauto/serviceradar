## ADDED Requirements

### Requirement: Explicit SNMP target credentials
An explicit SNMP target SHALL be polled with the first usable credential in this order: the SNMP override of the device that the target's host belongs to; an SNMP monitoring credential rule whose edge scope covers the compiling agent and whose target query selects that device; the target's own credential (its referenced reusable credential, else its inline material); the credential of the profile the target belongs to (its referenced reusable credential, else its inline material).
A host belongs to a device when it is the device's uid, a confirmed IP alias of the device, or the device's IP, hostname or name. A device override and a rule apply only through that device: neither MUST apply to a target whose host belongs to no device, whatever the rule's scope or priority. Such a target starts at its own credential.
A matching rule SHALL take precedence over the target's own credential. A credential meant for one device in preference to every rule is that device's SNMP override, which outranks rules for explicit and query-selected targets alike. An override or rule whose credential the secret broker refuses SHALL compile no poller target for the target rather than fall through to a lower-precedence credential, as for a query-selected device.
A target with no usable credential SHALL compile no poller target and SHALL be reported on every compile that skips it.

#### Scenario: A host no device holds gets no rule
- **GIVEN** two enabled SNMP monitoring rules scoped to agent A, one with target query `in:devices hostname:host01.example.com` and one with `in:devices hostname:host02.example.com`
- **AND** a profile with no credential of its own
- **AND** an explicit target on that profile with host `192.0.2.50`, which no device holds, and no credential of its own
- **WHEN** the target's profile is compiled for agent A
- **THEN** no poller target SHALL be compiled for it
- **AND** the compile SHALL report the target as having no credential

#### Scenario: A host no device holds is polled with its own credential
- **GIVEN** the same two rules
- **AND** an explicit target with host `192.0.2.51`, which no device holds, referencing reusable SNMP credential C
- **WHEN** the target's profile is compiled for agent A
- **THEN** the target SHALL be polled with C

#### Scenario: A rule that selects the target's device outranks the target's own credential
- **GIVEN** the same two rules
- **AND** a device with hostname `host02.example.com` and IP `192.0.2.52` and no SNMP override
- **AND** an explicit target with host `192.0.2.52` referencing reusable SNMP credential C
- **WHEN** the target's profile is compiled for agent A
- **THEN** the target SHALL be polled with the credential of the rule whose target query is `in:devices hostname:host02.example.com`, not with C

#### Scenario: The device override outranks every rule and the target's own credential
- **GIVEN** the same two rules
- **AND** a device with hostname `host02.example.com` and IP `192.0.2.53` that has an SNMP override O
- **AND** an explicit target with host `192.0.2.53` referencing reusable SNMP credential C
- **WHEN** the target's profile is compiled for agent A
- **THEN** the target SHALL be polled with O

#### Scenario: A target no rule selects falls back to its own credential, then its profile's
- **GIVEN** the same two rules
- **AND** a profile P referencing reusable SNMP credential R
- **AND** on P, an explicit target on a device with hostname `host03.example.com` referencing reusable SNMP credential C, an explicit target on a device with hostname `host04.example.com` with no credential of its own, and an explicit target on host `192.0.2.54`, which no device holds, with no credential of its own
- **AND** neither device has an SNMP override
- **WHEN** P is compiled for agent A
- **THEN** the first target SHALL be polled with C
- **AND** the other two SHALL be polled with R

#### Scenario: Upgrade keeps polling a target only the old fallback served
- **GIVEN** an explicit target with no credential of its own on a host no device holds
- **AND** every registered agent compiling its profile had, as its first enabled SNMP monitoring rule scoped to the agent or its partition, a rule referencing reusable credential R
- **WHEN** the one-time backfill runs after the upgrade
- **THEN** the target SHALL reference R
- **AND** a target whose agents had different first rules, or none, SHALL be left without a credential and reported
- **AND** a target with a credential of its own SHALL NOT be changed

## MODIFIED Requirements

### Requirement: Credential precedence
SNMP credential resolution SHALL follow the precedence order: per-device override > SNMP monitoring credential rule whose edge scope covers the compiling agent and whose target query selects the device > profile credentials.
The profile credentials of a device are those of the highest-priority profile whose target query selects it, else the default profile's; a device selected by the target query of the profile being compiled then falls back to that profile's credentials. An explicit target follows the same order with its own credential between the rule and the credentials of the profile it belongs to (Requirement: Explicit SNMP target credentials). Query-selected targets, explicit targets and Mapper's known-device targets SHALL resolve through one implementation of this order.

#### Scenario: Device override wins
- **GIVEN** a device with a per-device SNMP credential override
- **AND** a matching profile with different credentials
- **WHEN** SNMP config is compiled
- **THEN** the per-device override SHALL be used

#### Scenario: Device override wins over a matching rule
- **GIVEN** a device with a per-device SNMP credential override
- **AND** an enabled SNMP monitoring rule scoped to the compiling agent whose target query selects the device
- **WHEN** SNMP config is compiled
- **THEN** the per-device override SHALL be used
