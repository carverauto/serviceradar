## ADDED Requirements
### Requirement: Device SRQL shortcut searches
The web UI SHALL translate bare IP address and hostname input in SRQL search bars into explicit device SRQL queries before execution. Shortcut translation SHALL be visible in the submitted query state and SHALL preserve normal SRQL execution for inputs that already contain SRQL syntax.

#### Scenario: Bare IPv4 search
- **GIVEN** a user enters `192.168.2.10` in a device SRQL input
- **WHEN** the user submits the search
- **THEN** the UI SHALL execute an equivalent `in:devices ip:192.168.2.10` query
- **AND** the browser SHALL navigate to the device results page when submitted from a detail page

#### Scenario: Bare hostname search
- **GIVEN** a user enters `pve04` in a device SRQL input
- **WHEN** the user submits the search
- **THEN** the UI SHALL execute an equivalent device query matching hostname/name fields
- **AND** it SHALL not treat the hostname as an invalid SRQL query

#### Scenario: Existing SRQL remains unchanged
- **GIVEN** a user enters `in:devices metadata.proxmox_candidate:true`
- **WHEN** the user submits the search
- **THEN** the UI SHALL execute that SRQL query without shortcut rewriting
- **AND** detail pages SHALL navigate to `/devices` for device-scoped results.

### Requirement: Credential rule agent scope selector
The credential rule settings UI SHALL render `scope_value` as a dropdown of registered agents when `scope_type` is `agent`, and SHALL preserve freeform input for non-agent scopes.

#### Scenario: Agent scope uses registered agents
- **GIVEN** registered agents include `agent-sr-test-pve04`
- **WHEN** an admin creates or edits a credential rule and selects `scope_type=agent`
- **THEN** the scope value control SHALL be a select field containing `agent-sr-test-pve04`
- **AND** saving the rule SHALL persist the selected agent id

#### Scenario: Non-agent scope remains freeform
- **GIVEN** an admin selects `scope_type=partition`
- **WHEN** the form is rendered
- **THEN** the scope value control SHALL allow entering the partition identifier

### Requirement: Agents navigation entry
The authenticated operations navigation SHALL include an Agents entry that routes to `/agents`.

#### Scenario: User navigates to agents
- **GIVEN** a signed-in user can access agent inventory
- **WHEN** the operations shell renders
- **THEN** the navigation SHALL include an Agents item
- **AND** selecting it SHALL navigate to `/agents`

### Requirement: Services navigation entry
The authenticated operations navigation SHALL include a Services entry that routes to `/services`.

#### Scenario: User navigates to services
- **GIVEN** a signed-in user can access service inventory
- **WHEN** the operations shell renders
- **THEN** the navigation SHALL include a Services item
- **AND** selecting it SHALL navigate to `/services`

### Requirement: Edge Ops navigation has unique destinations
The Edge Ops and agent settings navigation SHALL expose release management, plugin management, and related agent operations with one clear link per destination. It SHALL NOT render duplicate Plugins links for the same destination on `/settings/agents/releases` or adjacent settings pages.

#### Scenario: Release settings navigation has one plugins link
- **GIVEN** a signed-in admin opens `/settings/agents/releases`
- **WHEN** the Edge Ops/settings navigation renders
- **THEN** it SHALL contain one link to plugin management
- **AND** it SHALL contain one clear link to release management
- **AND** duplicate Plugins entries SHALL not be shown

### Requirement: Web database connection lifecycle is stable
The web-ng application SHALL avoid repeated Postgrex `client exited` disconnect churn during normal page loads, imports, and settings workflows. Long-running or asynchronous work SHALL own database calls in supervised processes with explicit timeouts, and canceled UI processes SHALL not leave high-volume database checkout disconnect logs.

#### Scenario: Plugin import does not churn the database pool
- **GIVEN** an admin imports first-party plugins
- **WHEN** the import completes or fails
- **THEN** web-ng logs SHALL not emit repeated Postgrex disconnect messages for many pool connections caused by short-lived client exits

#### Scenario: Agent settings pages do not churn the database pool
- **GIVEN** an admin opens `/settings/agents/plugins` or `/settings/agents/releases`
- **WHEN** the page loads and refreshes its data
- **THEN** database queries SHALL complete through stable request/task lifecycles
- **AND** repeated Postgrex `client exited` disconnect logs SHALL not occur under normal operation
