## ADDED Requirements
### Requirement: Sysmon-vm obtains SPIFFE identity without shared sockets
The sysmon-vm checker SHALL bootstrap its own workload identity on standalone laptops (Docker or VM) without requiring a pre-installed SPIRE agent or shared host volumes.

#### Scenario: Embedded micro-agent joins upstream over the network
- **WHEN** an operator starts sysmon-vm with `ONBOARDING_TOKEN` (or `ONBOARDING_PACKAGE`) and `KV_ENDPOINT` on a laptop that has no poller workload socket available
- **THEN** the checker (or bundled `serviceradar-edge` helper) SHALL fetch the checker onboarding package from Core, read the SPIRE join token and trust bundle, start a bundled SPIRE workload agent that connects to the demo SPIRE server via its LoadBalancer address/port, and expose a local workload API socket for sysmon-vm to fetch an SVID
- **AND** sysmon-vm SHALL bind its gRPC server with that SVID so the demo poller/agent in Kubernetes accepts the connection.

#### Scenario: Prefer existing poller workload proxy when explicitly configured
- **WHEN** an operator provides a workload API override (for example `SPIRE_WORKLOAD_API=tcp://<poller-ip>:<port>`) alongside a valid onboarding token
- **THEN** sysmon-vm SHALL skip starting the bundled agent and instead consume the provided workload endpoint (including TLS trust root and expected SPIFFE ID) so it can reuse the poller’s SPIRE proxy without needing a shared Unix socket.

### Requirement: Checker onboarding packages deliver sysmon-vm join material
Core SHALL issue onboarding packages for sysmon-vm checkers that contain all identity artifacts needed for laptop installs and record activation.

#### Scenario: Checker package issued from demo namespace
- **WHEN** an admin issues a package with component type `checker` and kind `sysmon-vm` targeting the demo namespace
- **THEN** Core SHALL mint a SPIRE join token parented to the demo trust domain/parent ID, include the upstream trust bundle, and embed metadata (Core/KV endpoints, SPIRE upstream host/port) so the laptop bootstrap can reach the demo SPIRE server over the network without manual edits
- **AND** Core SHALL mark the checker as delivered/activated once the bundled agent presents the issued SPIFFE ID to the demo control plane.
