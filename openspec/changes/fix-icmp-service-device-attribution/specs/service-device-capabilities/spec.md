## ADDED Requirements
### Requirement: Device ID queries use exact-match engine
Device search queries containing `device_id:` filters SHALL use an engine that supports exact device ID matching (SRQL), not the registry engine which lacks device ID filtering.

#### Scenario: Device details page returns correct device
- **WHEN** the frontend requests device details for `serviceradar:agent:k8s-agent` via a `device_id:"serviceradar:agent:k8s-agent"` query
- **THEN** the search planner routes to SRQL (not registry), and the response contains only that device with its correct ICMP metrics and capability data.

#### Scenario: Registry engine rejects device_id queries
- **WHEN** the search planner evaluates a query containing `device_id:` filter
- **THEN** `supportsRegistry()` returns false, forcing the query through SRQL which correctly implements device_id filtering.

### Requirement: Core SRQL client authenticates correctly
The Core service's SRQL client SHALL be configured with the API key so SRQL queries authenticate successfully.

#### Scenario: Core SRQL queries succeed with auth
- **WHEN** the Core service calls SRQL for timeseries metrics or device queries
- **THEN** the SRQL client includes the `X-API-Key` header and receives a successful response (not 401).
