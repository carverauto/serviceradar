## ADDED Requirements

### Requirement: SRQL builder is reusable outside global search pages
The SRQL query builder SHALL expose reusable state, parsing, rendering, and event-handling primitives that can be embedded in feature-specific editors such as dashboard authoring without duplicating query construction logic.

#### Scenario: Embedded builder emits canonical SRQL
- **GIVEN** a feature editor embeds the SRQL builder for the `devices` entity
- **WHEN** the user chooses filters, sort, time, and limit through builder controls
- **THEN** the builder SHALL emit the same canonical SRQL string as the global SRQL search surface for the same state.

#### Scenario: Embedded builder preserves unsupported raw query
- **GIVEN** an embedded builder receives a valid SRQL query with clauses it cannot represent
- **WHEN** the editor loads that query
- **THEN** the builder SHALL expose an unsupported/unsynced state
- **AND** it SHALL NOT rewrite the raw query unless the user explicitly applies a representable builder state.

### Requirement: Dashboards SRQL entity supports hub discovery
The SRQL `in:dashboards` entity SHALL support querying both authored dashboards and enabled dashboard package routes available to the current user for dashboard hub discovery.

#### Scenario: Query returns accessible dashboard types
- **GIVEN** a user has access to authored dashboards and package dashboards
- **WHEN** the user runs `in:dashboards title:%availability%`
- **THEN** SRQL SHALL return matching dashboard rows from both sources
- **AND** each row SHALL identify whether it is an authored dashboard or package dashboard.

#### Scenario: Dashboard query respects access
- **GIVEN** a private authored dashboard exists for another user
- **WHEN** the current user runs `in:dashboards`
- **THEN** SRQL SHALL NOT return that private dashboard unless the current user has view access.
