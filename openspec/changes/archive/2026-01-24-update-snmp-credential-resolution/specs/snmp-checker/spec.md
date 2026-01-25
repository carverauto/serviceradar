## MODIFIED Requirements

### Requirement: SNMP Profile-Based Configuration
The SNMP monitoring system MUST support profile-based configuration where administrators define SNMP profiles that are assigned to devices via SRQL queries.

#### Scenario: Device receives profile via SRQL match
- **GIVEN** an SNMP profile with `target_query: "in:devices tags.snmp:enabled"`
- **AND** a device with tag `snmp: enabled`
- **WHEN** the agent requests its configuration
- **THEN** the agent receives the SNMP profile configuration (including credentials)

## ADDED Requirements

### Requirement: Profile credential inheritance
SNMP profiles SHALL store credentials (v1/v2c/v3) that can be applied to targets unless overridden per device.

#### Scenario: Target inherits profile credentials
- **GIVEN** a profile with SNMPv2c community "public"
- **AND** a device matched to that profile
- **WHEN** SNMP config is compiled
- **THEN** targets for that device SHALL use the profile credentials

### Requirement: Credential precedence
SNMP credential resolution SHALL follow the precedence order: per-device override > profile credentials.

#### Scenario: Device override wins
- **GIVEN** a device with a per-device SNMP credential override
- **AND** a matching profile with different credentials
- **WHEN** SNMP config is compiled
- **THEN** the per-device override SHALL be used

### Requirement: Profile priority ordering
When multiple profiles match a device, the system SHALL choose the highest-priority profile.

#### Scenario: Higher priority wins
- **GIVEN** two matching SNMP profiles with priorities 10 and 5
- **WHEN** SNMP config is compiled
- **THEN** the profile with priority 10 SHALL be selected
