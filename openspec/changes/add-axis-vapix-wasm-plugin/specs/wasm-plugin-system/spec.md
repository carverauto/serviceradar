## MODIFIED Requirements
### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

Plugin results MAY include optional enrichment and event blocks. When present, core ingestion SHALL parse and route them without breaking service status ingestion.

#### Scenario: Plugin result with enrichment and events
- **GIVEN** a plugin result payload containing valid `device_enrichment` and `events`
- **WHEN** the payload is ingested
- **THEN** service status ingestion SHALL still persist status/summary
- **AND** enrichment and event data SHALL be routed to their respective processors

#### Scenario: Plugin result without enrichment and events
- **GIVEN** a plugin result payload containing only status and summary
- **WHEN** the payload is ingested
- **THEN** ingestion SHALL behave exactly as before

### Requirement: Host Function Capabilities
Plugins SHALL access external resources only through declared host functions, and the agent SHALL enforce capability and permission checks on each call.

The runtime SHALL support authenticated HTTP requests through headers for VAPIX API access and SHALL continue enforcing allowlists for domains, networks, and ports.

#### Scenario: Authenticated VAPIX request succeeds with allowlist
- **GIVEN** a plugin configured with `http_request` capability and allowlisted AXIS domain/IP
- **AND** an HTTP request that includes authorization headers
- **WHEN** the plugin issues the request
- **THEN** the agent SHALL forward the request and return response payload to the plugin

#### Scenario: Authenticated request denied by allowlist
- **GIVEN** a plugin configured with `http_request` capability
- **AND** an HTTP request to a non-allowlisted AXIS endpoint
- **WHEN** the plugin issues the request
- **THEN** the agent SHALL deny the request regardless of headers
