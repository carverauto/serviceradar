## ADDED Requirements
### Requirement: Agent ICMP results stay attached to service devices
Agent-originated ICMP checks SHALL record capability snapshots and metrics against the agent service device whenever an `agent_id` is present, while preserving any target host or device identifiers in metadata for observability.

#### Scenario: ICMP payload includes device_id but agent capability persists
- **WHEN** an ICMP response from an agent includes a `device_id` derived from `host_ip` (for example `default:agent`) alongside `agent_id=k8s-agent`
- **THEN** the system records the ICMP capability snapshot and metrics on `serviceradar:agent:k8s-agent`, keeps the target host/device hints in metadata, and the device metrics summary reports ICMP availability for that agent.

### Requirement: Placeholder host identity does not block collector ICMP visibility
ICMP processing SHALL ignore non-IP host identifiers from agent configs when deriving device IDs and SHALL still emit ICMP capability hints so collector devices render ICMP sparklines in the UI.

#### Scenario: Placeholder host_ip still yields ICMP sparkline
- **WHEN** an agent ICMP payload carries a placeholder `host_ip` or `device_id` value that is not a valid IP address
- **THEN** the system falls back to the agent service device ID, retains the target host in metadata, and the device API returns `metrics_summary.icmp=true` with an ICMP capability snapshot for that agent so the inventory sparkline appears.
