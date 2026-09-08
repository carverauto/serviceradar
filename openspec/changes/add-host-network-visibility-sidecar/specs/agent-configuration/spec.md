## ADDED Requirements

### Requirement: Embedded sidecar manager initialisation

`serviceradar-agent` SHALL initialise the sidecar manager defined in
`agent-sidecar-runtime` during startup, registering `netprobe` when
the binary is present and the agent is running on a supported Linux
target. When the binary is absent (e.g. macOS or Windows builds) the
agent MUST NOT fail startup and MUST advertise the
`host-network-visibility` capability as unavailable.

#### Scenario: Linux agent registers the netprobe sidecar at startup
- **WHEN** `serviceradar-agent` starts on a Linux host with
  `/usr/local/lib/serviceradar/bin/serviceradar-netprobe` present
- **THEN** the sidecar manager registers the netprobe sidecar and
  begins its lifecycle before the agent reports `ready`

#### Scenario: Missing sidecar binary does not fail agent startup
- **WHEN** `serviceradar-agent` starts on a host without the netprobe
  binary
- **THEN** the agent starts successfully
- **AND** the agent's capability advertisement marks
  `host-network-visibility` as unavailable rather than enabled

### Requirement: Visibility sub-config refresh on push-config delivery

`serviceradar-agent` SHALL re-apply the new visibility bindings to the
supervised sidecar via its IPC `ApplyConfig` call before acknowledging
any push-config delivery whose `visibility_config` differs from the
currently-applied configuration.

#### Scenario: New profile binding reaches the sidecar before ack
- **WHEN** the control stream pushes a config update introducing a new
  device binding
- **THEN** the agent sends the updated `VisibilityAgentConfig` to the
  sidecar
- **AND** the agent acknowledges the push only after the sidecar
  acknowledges receipt

### Requirement: Kernel BPF support detected and reported

`serviceradar-agent` SHALL detect at startup whether the host kernel
supports the `CAP_BPF` / `CAP_PERFMON` split required for eBPF flow
attribution, propagate that determination to the sidecar via the
delivered configuration, and surface it in the agent's
`StatusResponse` capability bundle.

#### Scenario: Older kernel reports degraded capability
- **WHEN** the agent starts on a kernel that lacks the required BPF
  capability split
- **THEN** the agent advertises `host-network-visibility = degraded`
- **AND** the `StatusResponse` capability bundle reports
  `flow_attribution_available = false`
