## ADDED Requirements

### Requirement: Explicit SNMP target credentials
An explicit SNMP target SHALL be polled with an SNMP monitoring credential rule only when the rule's edge scope covers the compiling agent and the rule's target query selects the device that the target's host belongs to. A host belongs to a device when it is the device's uid, a confirmed IP alias of the device, or the device's IP, hostname or name.
A rule MUST NOT apply to a target whose host belongs to no device, whatever the rule's scope or priority. Such a target SHALL be polled with its own credential: its referenced reusable credential, else its inline material. A target with no usable credential SHALL compile no poller target and SHALL be reported on every compile that skips it.

#### Scenario: A host no device holds gets no rule
- **GIVEN** two enabled SNMP monitoring rules scoped to agent A, one with target query `in:devices hostname:host01.example.com` and one with `in:devices hostname:host02.example.com`
- **AND** an explicit target with host `192.0.2.50`, which no device holds, and no credential of its own
- **WHEN** the target's profile is compiled for agent A
- **THEN** no poller target SHALL be compiled for it
- **AND** the compile SHALL report the target as having no credential

#### Scenario: A host no device holds is polled with its own credential
- **GIVEN** the same two rules
- **AND** an explicit target with host `192.0.2.51`, which no device holds, referencing reusable SNMP credential C
- **WHEN** the target's profile is compiled for agent A
- **THEN** the target SHALL be polled with C

#### Scenario: A host whose device a rule selects is polled with that rule
- **GIVEN** the same two rules
- **AND** a device with hostname `host02.example.com` and IP `192.0.2.52`
- **AND** an explicit target with host `192.0.2.52`
- **WHEN** the target's profile is compiled for agent A
- **THEN** the target SHALL be polled with the credential of the rule whose target query is `in:devices hostname:host02.example.com`

#### Scenario: Upgrade keeps polling a target only the old fallback served
- **GIVEN** an explicit target with no credential of its own on a host no device holds
- **AND** every registered agent compiling its profile had, as its first enabled SNMP monitoring rule scoped to the agent or its partition, a rule referencing reusable credential R
- **WHEN** the one-time backfill runs after the upgrade
- **THEN** the target SHALL reference R
- **AND** a target whose agents had different first rules, or none, SHALL be left without a credential and reported
- **AND** a target with a credential of its own SHALL NOT be changed
