## ADDED Requirements
### Requirement: Remote access supports ServiceRadar-owned eBPF enhanced recording
The system SHALL support Linux eBPF enhanced recording for remote-access sessions through ServiceRadar-owned collector code or explicitly approved Apache-2.0 source provenance.

#### Scenario: Required eBPF tracing starts before target dial
- **GIVEN** a remote-access policy requires eBPF enhanced recording
- **AND** the selected Linux agent advertises `remote_access.bpf`
- **WHEN** the operator starts a remote-access session
- **THEN** the agent SHALL start the eBPF collector and bind it to the session boundary before dialing the target
- **AND** the target SHALL NOT be dialed if the eBPF collector fails to load, attach, or register the session.

#### Scenario: eBPF tracing is session-scoped
- **GIVEN** an active remote-access session with eBPF enhanced recording enabled
- **WHEN** unrelated processes execute commands, open files, or create network connections on the same host
- **THEN** those unrelated host events SHALL NOT be emitted as remote-access session events
- **AND** emitted events SHALL be correlated to the session, actor, target, selected agent, and policy snapshot.

#### Scenario: Agentless SSH cannot satisfy target-side command tracing
- **GIVEN** a generic SSH session is opened by an intermediate ServiceRadar agent to a separate target host
- **AND** the target host is not running a ServiceRadar-managed execution component for that session
- **WHEN** policy requires target-side command or file eBPF tracing
- **THEN** the system SHALL NOT treat the intermediate agent's eBPF support as satisfying that policy
- **AND** the session SHALL fail before target access unless policy explicitly allows a non-target-side fallback.

#### Scenario: Managed target satisfies target-side tracing
- **GIVEN** a target host runs a ServiceRadar-managed execution component that can place the remote-access shell process tree in a session boundary
- **WHEN** policy requires target-side command, file, or network eBPF tracing
- **THEN** the managed target component SHALL register the session boundary before the shell starts
- **AND** emitted eBPF events SHALL describe the target-side process tree rather than only the intermediate SSH client.

#### Scenario: Sensitive contents are not captured
- **GIVEN** eBPF enhanced recording observes commands, file activity, and network connections
- **WHEN** the agent emits enhanced events
- **THEN** events SHALL NOT contain private key bytes, passwords, terminal input bytes, or file contents
- **AND** argv, paths, and metadata SHALL be redacted according to policy before being forwarded.

#### Scenario: Dropped events are visible
- **GIVEN** kernel buffers, maps, or user-space queues drop enhanced-recording observations
- **WHEN** the agent reports enhanced recording telemetry
- **THEN** it SHALL emit loss events that identify the event family, source, and dropped-event count
- **AND** final session audit SHALL include whether enhanced recording was complete or degraded.

### Requirement: Teleport-derived BPF code follows license boundaries
The system SHALL NOT copy, translate, or mechanically port current Teleport AGPL BPF implementation code into ServiceRadar.

#### Scenario: Apache-era Teleport source is considered for reuse
- **GIVEN** an engineer proposes copying or adapting a Teleport v14 BPF source file
- **WHEN** the code is introduced
- **THEN** the change SHALL record the Teleport tag, commit, file path, license header, and dependency scan
- **AND** the copied code SHALL NOT include modifications derived from Teleport v15 or later AGPL source.

#### Scenario: Current Teleport BPF source is consulted
- **GIVEN** current Teleport BPF source has AGPL headers
- **WHEN** ServiceRadar implements equivalent BPF functionality
- **THEN** the implementation SHALL be clean-room and ServiceRadar-authored from public Linux interfaces, behavior requirements, and ServiceRadar tests.
