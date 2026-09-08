## ADDED Requirements
### Requirement: Sweep target compilation excludes inactive devices
Sweep target compilation SHALL exclude inactive devices from operational sweep targets, even when the source SRQL or saved targeting expression would otherwise match them.

#### Scenario: Device-targeted sweep skips inactive devices
- **GIVEN** a sweep group targets devices through `in:devices`
- **AND** one matching device has `is_active = false`
- **WHEN** the sweep config is compiled for an agent
- **THEN** the inactive device SHALL NOT be included in the generated sweep targets
