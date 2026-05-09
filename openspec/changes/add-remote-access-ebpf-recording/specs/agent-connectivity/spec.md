## ADDED Requirements
### Requirement: Agents advertise BPF capability only after runtime validation
Agents SHALL advertise `remote_access.bpf` only when the running binary, platform, kernel, permissions, and startup validation can support required eBPF enhanced recording.

#### Scenario: Binary lacks BPF build support
- **GIVEN** an agent binary is built without Linux eBPF collector support
- **WHEN** the agent sends Hello or control-stream heartbeat capabilities
- **THEN** it SHALL omit `remote_access.bpf`
- **AND** it MAY still advertise `remote_access.recording` for non-BPF recording or allowed fallback modes.

#### Scenario: Runtime validation fails
- **GIVEN** an agent binary includes eBPF collector support
- **AND** the host kernel, mounts, permissions, or self-test validation cannot support the collector
- **WHEN** the agent sends Hello or control-stream heartbeat capabilities
- **THEN** it SHALL omit `remote_access.bpf`
- **AND** the control plane SHALL NOT route sessions requiring eBPF enhanced recording to that agent.

### Requirement: Agents clean up BPF session state
Agents SHALL remove session-scoped BPF state when a remote-access session closes, expires, fails, or the agent shuts down.

#### Scenario: Session closes normally
- **GIVEN** a remote-access session is registered in BPF maps
- **WHEN** the session closes normally
- **THEN** the agent SHALL remove the session identifier from BPF maps
- **AND** no later host events SHALL be attributed to the closed session.

#### Scenario: Session fails during open
- **GIVEN** a remote-access session starts eBPF enhanced recording
- **WHEN** the target adapter fails before the session becomes active
- **THEN** the agent SHALL stop the collector or unregister the session
- **AND** it SHALL emit a sanitized terminal outcome without leaking target credentials.
