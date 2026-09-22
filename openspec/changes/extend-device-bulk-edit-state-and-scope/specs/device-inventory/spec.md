## MODIFIED Requirements

### Requirement: Bulk Tag Application

The system SHALL allow users to apply tags to multiple devices via bulk edit, and SHALL also apply a service state (in service or out of service) and a managed state (managed or unmanaged) from the same editor. "Out of service" SHALL mean `is_active = false`, the same flag `device_out_of_service?/1` reads; there is no separate out-of-service column and the agent-owned `is_available` bit MUST NOT be written. The operator SHALL choose an explicit target scope: only the current selection, or every device matching the SRQL query driving the page. A single scope control SHALL govern both the tag submit and the state submit, and cancelling the modal SHALL NOT change the selection or the scope. The existing 10,000-device cap and the unknown-selection-size guard SHALL be preserved. Agent-backed devices (`agent_id` present) MUST NOT be marked unmanaged, and the operator SHALL be told how many devices were skipped for that reason. The service and managed changes requested by one submit SHALL apply in a single transaction, so a failure of the second rolls back the first.

#### Scenario: Bulk apply tags to selected devices
- **GIVEN** a user selects multiple devices in the inventory list
- **WHEN** they use the bulk editor to add tags
- **THEN** the selected devices SHALL receive those tags

#### Scenario: Apply state changes to the selection
- **GIVEN** a user selects multiple devices in the inventory list
- **WHEN** they choose a service state, a managed state, or both in the bulk editor
- **AND** submit with the "Selected" scope
- **THEN** only the explicitly selected devices SHALL change

#### Scenario: Apply state changes to the whole SRQL result set
- **GIVEN** a user opens the bulk editor with an active SRQL filter
- **WHEN** they choose the "All N matching" scope and submit
- **THEN** every device matching the SRQL query SHALL change
- **AND** devices outside the query SHALL NOT change

#### Scenario: Cancelling the modal leaves the toolbar selection alone
- **GIVEN** a user with an existing toolbar selection
- **WHEN** they open the bulk editor, choose a scope, and cancel
- **THEN** the toolbar selection and its select-all-matching state SHALL be unchanged

#### Scenario: Agent-backed devices stay managed
- **GIVEN** a submit that marks devices unmanaged
- **AND** one or more targeted devices has `agent_id` set
- **WHEN** the submit completes
- **THEN** the agent-backed devices SHALL remain managed
- **AND** the success message SHALL report how many devices were skipped

#### Scenario: A failed second change rolls back the first
- **GIVEN** a submit that requests both a service change and a managed change
- **WHEN** the managed change fails after the service change succeeds
- **THEN** neither change SHALL persist
- **AND** the operator SHALL see a failure message
