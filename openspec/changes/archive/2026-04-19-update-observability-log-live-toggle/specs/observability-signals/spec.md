## ADDED Requirements

### Requirement: Opt-in live log streaming
The Observability logs pane SHALL default to standard paginated browsing with live updates disabled. The pane SHALL expose a header control that lets the operator explicitly enable live log streaming for the current view.

#### Scenario: Logs open in standard browsing mode
- **WHEN** a user opens the `/observability` logs pane
- **THEN** the logs list SHALL load as a normal paginated view
- **AND** incoming log-ingest refresh events SHALL NOT force the list to reload automatically

#### Scenario: Operator enables live mode
- **GIVEN** the user is viewing the logs pane
- **WHEN** the user activates the `Live` control in the pane header
- **THEN** the logs pane SHALL begin auto-refreshing as new logs arrive
- **AND** the UI SHALL indicate that live mode is active

#### Scenario: Manual browsing pauses live mode
- **GIVEN** live mode is active in the logs pane
- **WHEN** the user changes pagination, query text, or log filters
- **THEN** the logs pane SHALL pause live mode before applying the manual navigation change
- **AND** subsequent incoming log-ingest refresh events SHALL NOT reset the user's current page or query state unless live mode is enabled again
