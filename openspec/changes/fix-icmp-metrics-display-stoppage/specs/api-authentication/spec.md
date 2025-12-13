## MODIFIED Requirements

### Requirement: API Key Authentication Context Propagation

The system SHALL inject a valid user context into the request after successful API key authentication, allowing subsequent RBAC middleware to authorize the request.

#### Scenario: API key authenticated request accesses protected endpoint
- **WHEN** a request includes a valid `X-API-Key` header
- **AND** the API key matches the configured `API_KEY` environment variable
- **THEN** the system injects a service user into the request context with appropriate viewer roles
- **AND** the request proceeds to the protected endpoint
- **AND** the RBAC middleware authorizes the request based on the injected user

#### Scenario: API key authenticated request fetches device ICMP metrics
- **WHEN** a client calls `GET /api/devices/{id}/metrics?type=icmp` with valid API key
- **THEN** the system returns HTTP 200 with ICMP timeseries metrics
- **AND** the response includes metrics from the ring buffer or database fallback
