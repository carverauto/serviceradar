# Ansible Integration

## ADDED Requirements

### Requirement: The AWX bridge is dispatch-only
The AWX bridge plugin receives its token per dispatch and SHALL NOT be scheduled
as a periodic check.

#### Scenario: No periodic check is scheduled
- **GIVEN** an AWX bridge assignment on an agent
- **WHEN** the agent materialises plugin runners
- **THEN** no periodic `run_check` SHALL be scheduled for the bridge
- **AND** no `api_token is required` result SHALL be produced

#### Scenario: Dispatched commands still carry a grant
- **GIVEN** a command dispatched to the AWX bridge
- **WHEN** the agent injects the credential broker grant
- **THEN** the command SHALL execute with the resolved token
