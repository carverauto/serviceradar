# dusk-checker Specification

## Purpose
TBD - created by archiving change refactor-dusk-checker-wasm-plugin. Update Purpose after archive.
## Requirements
### Requirement: Dusk Checker Plugin Package
The dusk-checker plugin SHALL be packaged as a valid WASM plugin with manifest declaring WebSocket capabilities, and it SHALL connect to Dusk nodes to retrieve block data.

#### Scenario: Valid plugin manifest
- **GIVEN** the dusk-checker plugin package
- **WHEN** the package is validated
- **THEN** the manifest includes `id: dusk-checker`
- **AND** declares `websocket_request` capability
- **AND** specifies `outputs: serviceradar.plugin_result.v1`

#### Scenario: Plugin connects to Dusk node
- **GIVEN** a configured Dusk node address
- **WHEN** the plugin executes `run_check`
- **THEN** the plugin establishes a WebSocket connection to the node
- **AND** retrieves the current block information

### Requirement: Block Data Collection
The dusk-checker plugin SHALL subscribe to block acceptance events via the RUES protocol and report block height, hash, and timestamp in the result payload.

#### Scenario: Block data in result
- **GIVEN** a successful connection to a Dusk node
- **WHEN** the plugin retrieves block data
- **THEN** the result includes `block_height` metric
- **AND** the result includes `block_age_seconds` metric
- **AND** the result details include block hash and timestamp

#### Scenario: Node unreachable
- **GIVEN** a Dusk node that is not responding
- **WHEN** the plugin attempts to connect
- **THEN** the result status is `CRITICAL`
- **AND** the summary indicates connection failure

### Requirement: Plugin Configuration Schema
The dusk-checker plugin SHALL accept configuration specifying the node address and connection timeout, matching the existing DuskProfile schema.

#### Scenario: Configuration loaded
- **GIVEN** plugin configuration with `node_address` and `timeout`
- **WHEN** the plugin executes
- **THEN** it uses the configured node address for connection
- **AND** respects the configured timeout for connection attempts

#### Scenario: Missing configuration
- **GIVEN** plugin configuration without required `node_address`
- **WHEN** the plugin executes
- **THEN** the result status is `UNKNOWN`
- **AND** the summary indicates configuration error

### Requirement: WebSocket Host Function
The agent plugin runtime SHALL provide WebSocket host functions that plugins can use for bidirectional communication with external services.

#### Scenario: WebSocket connect and receive
- **GIVEN** a plugin with `websocket_request` capability
- **WHEN** the plugin calls `websocket_connect` with a valid URL
- **THEN** the host establishes the WebSocket connection
- **AND** returns a connection handle to the plugin

#### Scenario: WebSocket permission denied
- **GIVEN** a plugin without `websocket_request` capability
- **WHEN** the plugin calls `websocket_connect`
- **THEN** the host returns a permission error
- **AND** the connection is not established

### Requirement: Embedded Dusk Code Removal
The serviceradar-agent SHALL NOT include embedded dusk checker code after migration is complete.

#### Scenario: No embedded dusk service
- **GIVEN** an agent binary built after migration
- **WHEN** the agent starts without dusk plugin assignment
- **THEN** no dusk-related code is initialized
- **AND** the agent binary size is reduced

#### Scenario: Plugin-based dusk monitoring
- **GIVEN** an agent with dusk-checker plugin assigned
- **WHEN** the agent executes the plugin on schedule
- **THEN** dusk monitoring results are reported through the plugin result pipeline
- **AND** the gateway receives `GatewayServiceStatus` with plugin results

### Requirement: WebSocket SDK Support
The serviceradar-sdk-go SHALL provide WebSocket convenience wrappers that use the host WebSocket functions, following the same patterns as TCP and HTTP wrappers.

#### Scenario: SDK WebSocket connect
- **GIVEN** a plugin using the SDK
- **WHEN** the plugin calls `sdk.WebSocketConnect(url, timeout)`
- **THEN** the SDK invokes the `websocket_connect` host function
- **AND** returns a `WebSocketConn` handle on success

#### Scenario: SDK WebSocket send and receive
- **GIVEN** an established WebSocket connection via SDK
- **WHEN** the plugin calls `conn.Send(data)` or `conn.Recv(buf)`
- **THEN** the SDK invokes the appropriate host function
- **AND** handles errors consistently with other SDK network operations

