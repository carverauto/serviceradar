## ADDED Requirements
### Requirement: Standard SNMP OID templates are seeded product data
The system SHALL write the Standard vendor OID templates into the database as built-in templates under fixed ids on every install, so an SNMP profile can reference them. Seeding SHALL create only templates missing by id, SHALL NOT rewrite an existing row, and SHALL NOT replace an operator's template that holds the same vendor and name. Only the system actor SHALL be able to create a built-in template, and built-in templates SHALL remain read-only to operators. Every seeded OID SHALL be pollable through a profile: a scalar instance (ending in `.0`) is read with a GET, and a table column is walked.

The vendor templates (Cisco, Juniper, Arista) remain a browsing catalog for copying OIDs into explicit targets and custom templates; they are not seeded.

#### Scenario: Seeding is idempotent
- **GIVEN** an install with none of the built-in templates
- **WHEN** the built-in templates are seeded twice
- **THEN** the first pass creates each Standard template under its fixed id with `is_builtin: true`
- **AND** the second pass creates nothing

#### Scenario: An operator's same-named template is kept
- **GIVEN** an operator template with vendor `Standard` and the name of a built-in template
- **WHEN** the built-in templates are seeded
- **THEN** the operator template is unchanged and remains custom
- **AND** the other built-in templates are created

#### Scenario: Interface counters are walked
- **GIVEN** a profile referencing the built-in Interface Counters template
- **WHEN** the profile is compiled for a device it selects
- **THEN** the target carries `ifHCInOctets`, `ifHCOutOctets`, `ifHCInUcastPkts`, `ifHCOutUcastPkts`, `ifInErrors`, `ifOutErrors`, `ifInDiscards`, `ifOutDiscards` and `ifOperStatus` in walk mode

#### Scenario: An operator cannot mint a built-in template
- **WHEN** an administrator calls the built-in seeding action
- **THEN** the request is forbidden

### Requirement: The default SNMP profile polls the standard templates
The default SNMP profile SHALL reference the built-in System Uptime and Interface Counters templates unless an operator has chosen its templates. On upgrade, a default profile with an empty template list SHALL be given those two templates; a default profile that lists any template SHALL be left unchanged. An install created from the schema baseline, whose baseline recorded the starter-profile seed as applied without writing its row, SHALL receive the starter default profile with those templates when it has no SNMP profile. An install whose profiles an operator deleted SHALL NOT be given one back.

#### Scenario: Existing empty default profile
- **GIVEN** an enabled default profile with no OID templates
- **WHEN** the release's migrations run
- **THEN** the profile references System Uptime and Interface Counters

#### Scenario: Operator-chosen templates are kept
- **GIVEN** a default profile that references an operator's template
- **WHEN** the release's migrations run
- **THEN** its template list is unchanged

#### Scenario: Fresh install from the schema baseline
- **GIVEN** an empty database created from a schema baseline that includes the starter-profile seed's version
- **WHEN** the release's migrations run
- **THEN** one enabled default profile exists with `target_query: "in:devices"` and the two standard templates

#### Scenario: No profile on a replayed install stays no profile
- **GIVEN** an install not created from the schema baseline whose operator deleted every SNMP profile
- **WHEN** the release's migrations run
- **THEN** no SNMP profile is created

### Requirement: An SNMP profile that selects devices it cannot poll is reported
The system SHALL report an enabled SNMP profile whose normalized target query selects devices while its OID templates name no OID, because no target is compiled for those devices. Each compile of such a profile SHALL emit the `[:serviceradar, :snmp, :profile_without_oids]` telemetry event with the profile and agent, and core SHALL log a warning when the condition starts for that profile and agent or its target query changes, not on every compile. The SNMP profile list in settings SHALL mark such a profile **No OIDs** with the same message. Saving such a profile SHALL NOT be refused, since its templates can be destroyed or emptied after it is saved.

#### Scenario: Compile reports a profile without OIDs
- **GIVEN** an enabled profile whose target query selects a device and whose templates name no OID
- **WHEN** the profile is compiled for an agent
- **THEN** the compile succeeds with no query targets
- **AND** the `profile_without_oids` telemetry event names the profile and the agent

#### Scenario: Attaching a template clears the report
- **GIVEN** the profile above
- **WHEN** a template naming an OID is attached and the profile is compiled again
- **THEN** the device is compiled as a target
- **AND** no `profile_without_oids` event is emitted

#### Scenario: Settings marks the profile
- **GIVEN** one enabled profile with a target query and no OIDs, and one with a template naming an OID
- **WHEN** an administrator opens the SNMP profile list
- **THEN** only the first profile shows the **No OIDs** badge
