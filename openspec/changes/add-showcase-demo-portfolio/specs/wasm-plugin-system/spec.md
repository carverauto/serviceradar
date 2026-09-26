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
