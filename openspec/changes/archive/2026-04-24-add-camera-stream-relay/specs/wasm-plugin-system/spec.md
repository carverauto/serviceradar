## MODIFIED Requirements
### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

Plugin results MAY include optional enrichment and event blocks. Camera-capable plugins MAY also publish camera source and stream descriptors for downstream inventory/relay use. Plugin results MUST NOT carry continuous live media payloads.

#### Scenario: Camera discovery plugin publishes descriptors
- **GIVEN** a camera discovery plugin result containing source identifiers, stream descriptors, and status
- **WHEN** the payload is ingested
- **THEN** service status ingestion SHALL still preserve the plugin status
- **AND** the camera descriptors SHALL be routed into camera inventory processing
- **AND** no live media bytes SHALL be expected in the plugin result payload

#### Scenario: Plugin result without camera descriptors
- **GIVEN** a standard plugin result payload containing only status and summary
- **WHEN** the payload is ingested
- **THEN** ingestion SHALL behave exactly as before
