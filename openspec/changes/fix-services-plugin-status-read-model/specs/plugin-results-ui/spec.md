## MODIFIED Requirements
### Requirement: Services page custom result rendering
The Services page SHALL render plugin check results using the stored display contract when present, and fall back to the generic view otherwise. The Services page SHALL source active plugin cards from the persisted current service state read model on initial page load so a browser reload does not wait for PubSub or the next scheduled status check before showing the latest known plugin result.

#### Scenario: Custom result view
- **WHEN** a user opens a service check whose plugin package includes a display contract
- **THEN** the UI renders the results using the specified widgets and mappings

#### Scenario: Fallback result view
- **WHEN** a user opens a service check whose plugin package has no display contract
- **THEN** the UI renders the generic result view

#### Scenario: Reload uses persisted current state
- **GIVEN** a plugin produced an OK result that was persisted to the current service state read model
- **WHEN** a user reloads `/services`
- **THEN** the service card shows OK on the first render after data load
- **AND** the page does not show `plugin assignment pending result` while waiting for the next plugin execution

#### Scenario: Failures remain visible after reload
- **GIVEN** a plugin produced a failure result that was persisted to the current service state read model
- **WHEN** a user reloads `/services`
- **THEN** the service card shows FAIL with the latest failure summary
- **AND** the card remains sorted before healthy plugin services

### Requirement: Runtime result instructions
The system SHALL accept plugin result payloads that include runtime display instructions with data for supported widgets. Runtime display instructions SHALL be preserved in historical service details and in the current service state read model so compact `/services` cards and service detail pages render consistently after reload.

#### Scenario: Dynamic widget instructions
- **WHEN** a plugin result payload includes display instructions
- **THEN** the Services UI renders widgets based on those instructions using the stored display contract and schema version

#### Scenario: Persisted display instructions survive reload
- **GIVEN** a plugin result payload includes supported compact display instructions
- **WHEN** the result is ingested and a user reloads `/services`
- **THEN** the card renders the same supported compact widgets from persisted current state
