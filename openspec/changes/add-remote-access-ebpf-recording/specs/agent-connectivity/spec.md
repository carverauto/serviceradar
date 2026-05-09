## ADDED Requirements
### Requirement: Agents use one shared eBPF runtime
Agents SHALL use a single shared eBPF runtime/loader boundary for ServiceRadar-owned eBPF features instead of creating feature-specific eBPF runtimes.

#### Scenario: New agent feature needs eBPF
- **GIVEN** a future agent feature needs Linux eBPF programs, maps, links, ring buffers, or capability checks
- **WHEN** the feature is implemented
- **THEN** it SHALL integrate with the shared agent eBPF runtime
- **AND** it SHALL NOT introduce a separate loader, map manager, ring-buffer loop, or kernel compatibility checker unless the proposal documents a technical blocker.

#### Scenario: Remote access consumes shared runtime
- **GIVEN** remote-access enhanced recording needs command, file, and network probes
- **WHEN** the agent starts eBPF enhanced recording for a session
- **THEN** remote access SHALL register session-scoped probes and event normalization on top of the shared runtime
- **AND** shared runtime ownership SHALL remain outside the remote-access adapter package.

#### Scenario: Classic socket BPF remains separate
- **GIVEN** existing packet capture code uses classic socket BPF filters through `golang.org/x/sys/unix`
- **WHEN** the shared eBPF runtime is introduced
- **THEN** that classic BPF path MAY remain separate
- **AND** any later unification SHALL be explicit rather than forced by the remote-access eBPF collector.

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

#### Scenario: Deployment has only raw-socket capability
- **GIVEN** an agent deployment grants `NET_RAW` for ICMP or packet probing
- **AND** it does not explicitly enable the BPF runtime profile with required mounts, capabilities, and runtime checks
- **WHEN** the agent reports capabilities
- **THEN** it SHALL omit `remote_access.bpf`
- **AND** it SHALL report BPF as disabled rather than inferring support from raw-socket access.

#### Scenario: Deployment explicitly enables BPF profile
- **GIVEN** an agent deployment explicitly enables the BPF runtime profile
- **AND** the binary, kernel, mounts, capabilities, and startup self-test all pass
- **WHEN** the agent reports capabilities
- **THEN** it MAY advertise `remote_access.bpf`
- **AND** its capability report SHALL include enough version and status metadata for the control plane to route required-BPF sessions safely.

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

### Requirement: Agents enforce eBPF execution-boundary compatibility
Agents SHALL fail closed when a remote-access policy requires target-side eBPF tracing but the adapter cannot place the actual target execution context into a ServiceRadar-managed session boundary.

#### Scenario: Adapter cannot scope target process tree
- **GIVEN** a remote-access policy requires target-side command or file eBPF tracing
- **AND** the selected adapter only opens an outbound client connection to another host
- **WHEN** the adapter cannot register the target shell process tree with the shared eBPF runtime
- **THEN** the agent SHALL reject the open before target access
- **AND** it SHALL report a sanitized capability or policy failure.

#### Scenario: Adapter scopes local process tree
- **GIVEN** a remote-access adapter starts a local PTY process on the same Linux host as the ServiceRadar agent
- **WHEN** eBPF enhanced recording is enabled for that session
- **THEN** the agent SHALL register the local process tree with the shared eBPF runtime before the PTY starts
- **AND** it SHALL unregister the process tree when the session closes or fails.
