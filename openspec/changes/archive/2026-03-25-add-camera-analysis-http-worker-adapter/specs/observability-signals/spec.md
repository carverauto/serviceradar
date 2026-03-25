## ADDED Requirements
### Requirement: HTTP worker results are normalized into observability state
The system SHALL normalize successful HTTP worker responses through the camera analysis result contract before ingesting them into observability state.

#### Scenario: Worker returns a detection payload
- **GIVEN** the platform dispatches a bounded analysis input to an HTTP worker
- **WHEN** the worker returns a valid result payload
- **THEN** the platform SHALL normalize the response as camera analysis output
- **AND** SHALL ingest the derived result through the normal observability event surfaces

### Requirement: Worker failures are observable
The system SHALL expose HTTP analysis worker failures and dropped work through telemetry.

#### Scenario: Worker times out
- **GIVEN** the platform dispatches a bounded analysis input to an HTTP worker
- **WHEN** the worker times out or returns an invalid response
- **THEN** the platform SHALL record the failure as analysis dispatch telemetry
- **AND** SHALL distinguish worker failure from raw relay session failure
