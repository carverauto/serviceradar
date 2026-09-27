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
The platform SHALL accept a time-bounded run override in a plugin action result, retain it for the plugin assignment until it expires or is ended by a later action, pass every active override to each run of that assignment, and deliver an expired override marked expired to runs of that assignment until one reports success, for at most seven days after expiry.
Overrides SHALL carry an expiry no later than the maximum duration the plugin's action descriptor declares.

#### Scenario: Override reaches later runs
- **WHEN** an action result sets an override expiring in ten minutes
- **THEN** every run of that assignment during the next ten minutes SHALL receive the override
- **AND** runs after the expiry signal SHALL NOT receive it

#### Scenario: Override expiry is signalled until acknowledged
- **WHEN** an override expires without being ended early
- **THEN** the first run of that assignment after expiry SHALL receive the override marked expired
- **AND** the platform SHALL discard the override only after a run that received it marked expired reports success, so later runs SHALL NOT receive it

#### Scenario: Expiry run fails or does not happen
- **WHEN** the first run after expiry fails, is cancelled, or does not occur because the assignment is paused
- **THEN** the platform SHALL keep the expired override and deliver it marked expired to the next run of that assignment
- **AND** a resolving event repeated by that retry SHALL be safe for the receiving plugin to emit, because it carries the override's id and resolving an already-resolved alert is a no-op

#### Scenario: Excessive duration
- **WHEN** an action result requests an override longer than the descriptor's maximum duration
- **THEN** the platform SHALL clamp the expiry to the maximum

#### Scenario: Override ended early
- **WHEN** a later action ends an active override
- **THEN** the next run SHALL NOT receive it, expired or otherwise

#### Scenario: Unacknowledged expired override is bounded
- **WHEN** an expired override is never acknowledged because no run of its assignment succeeds, for example while the assignment is paused
- **THEN** the platform SHALL stop delivering it seven days after its expiry

### Requirement: Plugin actions can emit events
The platform SHALL let a plugin action entrypoint emit OCSF events through the same ingestion path as plugin run results, attributed to the plugin and assignment, so that the events reach the events store and alert engine without waiting for the next run.
Emission SHALL be subject to the action's RBAC and audit and SHALL be rejected when the plugin lacks the event-emission capability.

#### Scenario: Action emits an event
- **WHEN** an action entrypoint emits an OCSF event
- **THEN** the event SHALL be persisted with the plugin's source attribution
- **AND** SHALL be visible to alert evaluation within seconds

#### Scenario: Capability not granted
- **WHEN** an action entrypoint emits an event and the plugin does not hold the event-emission capability
- **THEN** the platform SHALL reject the call and SHALL NOT persist an event
