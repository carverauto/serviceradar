## MODIFIED Requirements
### Requirement: Axis event extraction
The AXIS plugin SHALL collect AXIS camera events and map them to OCSF Event Log Activity records for downstream ingestion, and it SHALL authenticate websocket event collection without embedding operator credentials in the websocket URL.

#### Scenario: Event mapped to OCSF
- **GIVEN** an AXIS camera event notification from the configured event source
- **WHEN** the plugin processes the notification
- **THEN** it SHALL emit a mapped OCSF event with timestamp, severity, and message fields

#### Scenario: Websocket auth avoids credential-bearing URLs
- **GIVEN** valid AXIS credentials and event collection enabled
- **WHEN** the plugin opens the VAPIX websocket event stream
- **THEN** it SHALL send a credential-free websocket URL to the host runtime
- **AND** it SHALL carry authentication in explicit request metadata instead of URL userinfo
