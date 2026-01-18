## ADDED Requirements

### Requirement: File-Based Configuration Source

The `serviceradar-agent` MUST load all configuration from local filesystem or gRPC-delivered configuration only. KV-backed configuration is not supported.

#### Scenario: Agent starts with file configuration
- **GIVEN** the agent has `CONFIG_SOURCE=file` environment variable (or unset)
- **AND** configuration files exist in `/etc/serviceradar/`
- **WHEN** the agent starts
- **THEN** configuration is loaded from the local filesystem
- **AND** the agent starts successfully

#### Scenario: Agent handles deprecated KV configuration source gracefully
- **GIVEN** the agent has `CONFIG_SOURCE=kv` environment variable
- **WHEN** the agent attempts to load configuration
- **THEN** the agent logs a deprecation warning
- **AND** the agent falls back to file-based configuration
- **AND** the agent starts successfully

#### Scenario: Agent uses environment-based configuration
- **GIVEN** the agent has `CONFIG_SOURCE=env` environment variable
- **AND** required configuration is available in environment variables
- **WHEN** the agent starts
- **THEN** configuration is loaded from environment variables
- **AND** the agent starts successfully

### Requirement: Push-Only Agent Communication

The agent gateway MUST NOT initiate connections to agents. All communication flows from agents to the gateway via gRPC push.

#### Scenario: Agent pushes status to gateway
- **GIVEN** an agent is connected to a gateway
- **WHEN** the agent's push interval elapses
- **THEN** the agent initiates a gRPC call to push status
- **AND** the gateway receives and processes the status

#### Scenario: Gateway does not poll agents
- **GIVEN** an agent gateway is running
- **WHEN** the gateway supervisor starts
- **THEN** no AgentClient polling process is started
- **AND** the gateway never initiates `GetStatus` calls to agents
