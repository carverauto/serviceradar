## MODIFIED Requirements
### Requirement: Authenticated Query API
The SRQL standalone HTTP service SHALL require an API authentication secret before serving query or translation endpoints. Requests to `/api/query` and `/translate` SHALL be rejected unless the configured API key is presented, and the standalone service SHALL NOT start if neither an environment-provided nor KV-backed API key is available. Embedded in-process SRQL construction used for local tests MAY bypass external API auth when it does not expose the standalone HTTP listener.

#### Scenario: Missing API key blocks standalone startup
- **GIVEN** the standalone SRQL service is starting
- **AND** neither `SRQL_API_KEY` nor a valid `SRQL_API_KEY_KV_KEY` provides an API key
- **WHEN** server initialization runs
- **THEN** startup SHALL fail before the HTTP listener is bound
- **AND** the query endpoints SHALL NOT be served unauthenticated

#### Scenario: Environment API key authenticates query requests
- **GIVEN** the standalone SRQL service is started with `SRQL_API_KEY`
- **WHEN** a client calls `/api/query` with the matching `x-api-key`
- **THEN** the request SHALL be authenticated and processed

#### Scenario: KV-backed API key authenticates query requests
- **GIVEN** the standalone SRQL service is started with `SRQL_API_KEY_KV_KEY`
- **AND** the referenced KV entry contains a non-empty API key
- **WHEN** a client calls `/translate` with the matching `x-api-key`
- **THEN** the request SHALL be authenticated and processed
