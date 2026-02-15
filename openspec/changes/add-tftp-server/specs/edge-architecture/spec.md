## ADDED Requirements

### Requirement: TFTP Command Bus Integration
The command bus SHALL support TFTP-specific command types (`tftp.start_receive`, `tftp.start_serve`, `tftp.stop_session`, `tftp.status`, `tftp.stage_image`) routed through the existing control stream. TFTP commands MUST follow the same lifecycle as existing command types (ack → progress → result). Agents MUST declare `"tftp"` in their capabilities during enrollment to receive TFTP commands.

#### Scenario: TFTP receive command routing
- **WHEN** a `tftp.start_receive` command is dispatched via the command bus
- **THEN** the command flows through core-elx → agent-gateway → agent control stream
- **AND** the agent starts a TFTP server in write-accept mode
- **AND** the agent sends back `CommandAck`, `CommandProgress`, and `CommandResult` messages

#### Scenario: TFTP serve command routing
- **WHEN** a `tftp.start_serve` command is dispatched after image staging completes
- **THEN** the agent starts a TFTP server in read-serve mode for the staged image
- **AND** progress and result messages flow back through the command bus

#### Scenario: TFTP capability filtering
- **WHEN** a TFTP command is dispatched targeting a specific agent
- **THEN** the command bus validates the agent has the `"tftp"` capability before dispatching
- **AND** rejects the dispatch if the capability is missing

### Requirement: Bidirectional Agent File Transfer via gRPC Streaming
Agents SHALL transfer files bidirectionally with the agent-gateway via dedicated gRPC streaming RPCs (`UploadFile`, `DownloadFile`) added to `AgentGatewayService`. The agent does NOT have access to NATS JetStream; the gateway acts as a relay between the agent (gRPC) and core-elx (Erlang RPC). For **receive mode**, agents stream received files to the gateway via `UploadFile`. For **serve mode**, agents pull firmware images from the gateway via `DownloadFile`. The gateway forwards data to/from core-elx, which handles final storage.

#### Scenario: Agent uploads received file via gRPC
- **WHEN** an agent completes receiving a file via TFTP in receive mode
- **THEN** the agent streams the file to the gateway via `UploadFile` gRPC using chunked `FileChunk` messages
- **AND** the gateway forwards the data to core-elx via Erlang RPC
- **AND** core-elx persists the file to the configured storage backend (local or S3)
- **AND** the file is removed from the agent's staging directory after successful upload

#### Scenario: Agent downloads image for serving via gRPC
- **WHEN** a serve-mode TFTP session is created and staging is initiated
- **THEN** the agent calls `DownloadFile` gRPC on the gateway with the session ID
- **AND** the gateway fetches the image from core-elx (which reads from local/S3 storage)
- **AND** the gateway streams the image to the agent via chunked `FileChunk` messages
- **AND** the agent verifies the SHA-256 hash before making the image available for TFTP serving
