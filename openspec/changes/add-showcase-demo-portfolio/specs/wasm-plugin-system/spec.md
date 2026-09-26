## ADDED Requirements

### Requirement: Plugins can report topology links
The platform SHALL ingest `serviceradar.topology_links.v1` observations from plugin results as plugin-sourced topology links with provenance `plugin:<plugin id>`, resolving each endpoint to a device through the identities the plugin reported.
Links whose endpoints cannot be resolved SHALL be dropped and counted, not stored with placeholder endpoints.

#### Scenario: Link between known devices
- **WHEN** a plugin result carries a link whose two endpoints resolve to devices
- **THEN** the topology view SHALL show that link with its kind and `plugin:<plugin id>` provenance

#### Scenario: Unresolvable endpoint
- **WHEN** a link references an identity no device matches
- **THEN** the platform SHALL NOT store the link
- **AND** SHALL increment an unresolved-link counter for that plugin

#### Scenario: Plugin stops reporting a link
- **WHEN** a plugin omits a previously reported link for longer than the link's staleness window
- **THEN** the platform SHALL mark the link stale

### Requirement: Plugin actions can set time-bounded run overrides
The platform SHALL accept a time-bounded run override in a plugin action result, retain it for the plugin assignment until it expires or is ended by a later action, and pass every active override to each run of that assignment.
Overrides SHALL carry an expiry no later than the maximum duration the plugin's action descriptor declares.

#### Scenario: Override reaches later runs
- **WHEN** an action result sets an override expiring in ten minutes
- **THEN** every run of that assignment during the next ten minutes SHALL receive the override
- **AND** runs after expiry SHALL NOT receive it

#### Scenario: Override ended early
- **WHEN** a later action ends an active override
- **THEN** the next run SHALL NOT receive it

#### Scenario: Excessive duration
- **WHEN** an action result requests an override longer than the descriptor's maximum duration
- **THEN** the platform SHALL clamp the expiry to the maximum
