## ADDED Requirements
### Requirement: Stored inline SNMP credentials can be removed
The system SHALL let an operator remove an inline SNMP community string, auth password or privacy password stored on an SNMP profile, SNMP target or per-device SNMP override through an explicit `clear_credentials` input, and SHALL NOT treat a blank credential value as a removal.
A call that binds a different reusable credential SHALL remove the inline credential material the record stores, because credential resolution never reads it while a reusable credential is bound. Re-sending the reusable credential already bound SHALL NOT remove it. A call that supplies a reusable credential, changed or re-sent, SHALL NOT also supply an inline credential value.

#### Scenario: Blank value keeps the stored credential
- **GIVEN** an SNMP profile with a stored community string
- **WHEN** the profile is updated with a blank community value
- **THEN** the stored community string is unchanged

#### Scenario: Explicit removal clears the stored credential
- **GIVEN** an SNMP profile with a stored community string
- **WHEN** the profile is updated with `clear_credentials` naming `community`
- **THEN** the profile no longer stores a community string

#### Scenario: Binding a reusable credential removes inline material
- **GIVEN** an SNMPv2c profile with a stored community string
- **WHEN** the profile is switched to SNMPv3 and bound to a reusable credential
- **THEN** the profile no longer stores a community string

#### Scenario: Conflicting inputs are rejected
- **GIVEN** an SNMP profile with a stored community string
- **WHEN** an update supplies a community value and also lists `community` in `clear_credentials`, or supplies a community value together with a reusable credential
- **THEN** the update is rejected and the stored community string is unchanged

#### Scenario: Operator removes a credential in settings
- **GIVEN** an SNMP profile edit form for a profile with a stored community string
- **WHEN** the operator ticks the removal control for it and saves
- **THEN** the profile no longer stores a community string
