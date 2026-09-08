## ADDED Requirements
### Requirement: First-party plugin repository release selector
The first-party repository plugin settings UI SHALL display plugins from the latest indexed release by default and SHALL provide an explicit release selector for viewing plugins from older indexed releases. It SHALL NOT render one undifferentiated table containing every plugin entry from every indexed release.

#### Scenario: Latest release plugins are shown by default
- **GIVEN** the first-party repository index contains five indexed releases
- **WHEN** an operator opens `/settings/agents/plugins`
- **THEN** the First-party Repository Plugins section SHALL show only plugins from the latest indexed release by default
- **AND** the summary text SHALL identify the selected release and plugin count for that release

#### Scenario: Operator views an older release
- **GIVEN** older indexed releases are available
- **WHEN** the operator selects an older release from the release dropdown
- **THEN** the table SHALL update to show plugin entries from only that selected release
- **AND** the latest release SHALL remain easy to reselect

#### Scenario: Plugin rows remain release-scoped
- **GIVEN** two releases contain a plugin with the same package name
- **WHEN** the latest release is selected
- **THEN** only the latest release's row for that package SHALL be displayed
- **AND** rows from older releases SHALL not be mixed into the same table

### Requirement: Plugin blobs use NATS Object Store
Imported plugin package blobs SHALL be persisted in NATS Object Store. The application SHALL NOT expose filesystem blob storage as a supported backend for imported plugins in deployed ServiceRadar environments.

#### Scenario: Imported plugin blob is stored in Object Store
- **GIVEN** first-party plugin import downloads a signed Wasm artifact
- **WHEN** the artifact is accepted
- **THEN** the plugin blob SHALL be written to the configured NATS Object Store bucket
- **AND** package metadata SHALL reference the object key rather than a filesystem path

#### Scenario: Plugin blob survives web pod restart
- **GIVEN** an imported plugin package exists
- **WHEN** the web-ng pod restarts or is rescheduled
- **THEN** the plugin blob SHALL remain available from NATS Object Store
- **AND** no writable application filesystem volume SHALL be required for plugin blob persistence

#### Scenario: Filesystem storage is not a deployed backend
- **GIVEN** ServiceRadar starts in a deployed Kubernetes environment
- **WHEN** plugin storage configuration is loaded
- **THEN** filesystem storage SHALL not be selected as an application backend
- **AND** unsupported filesystem backend configuration SHALL fail fast or be ignored with a clear configuration error
