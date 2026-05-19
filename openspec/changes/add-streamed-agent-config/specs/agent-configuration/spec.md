## MODIFIED Requirements
### Requirement: Remote Configuration Fetch
The `serviceradar-agent` MUST fetch its sysmon and unified agent configuration from the control plane via gRPC when no local override exists. Agents that support streamed config MUST prefer streamed gateway-to-agent config delivery and apply the decoded response through the same configuration resolution path as unary `GetConfig`.

#### Scenario: Fetch config on startup
- **GIVEN** a registered agent without local sysmon.json
- **WHEN** the agent process starts
- **THEN** it requests its effective configuration from the gateway
- **AND** it prefers the streamed config endpoint when available
- **AND** it receives a complete `AgentConfigResponse` with all monitoring parameters after reassembling streamed chunks

#### Scenario: Config fetch failure with fallback
- **GIVEN** an agent starting up
- **AND** the control plane is unreachable or the streamed config response is incomplete, malformed, oversized, or checksum-mismatched
- **WHEN** the agent attempts to fetch configuration
- **THEN** it retries with exponential backoff (max 5 attempts)
- **AND** falls back to cached configuration if available
- **AND** uses default profile if no cache exists

#### Scenario: Config fetch timeout
- **GIVEN** an agent attempting to fetch configuration
- **WHEN** the request takes longer than 30 seconds
- **THEN** the request times out
- **AND** the agent proceeds with fallback logic

#### Scenario: Unary fallback for older gateway
- **GIVEN** an agent that supports streamed config
- **AND** the connected gateway returns `Unimplemented` for streamed config
- **WHEN** the agent fetches remote configuration
- **THEN** it falls back to unary `GetConfig`
- **AND** applies the returned config through the existing configuration path
