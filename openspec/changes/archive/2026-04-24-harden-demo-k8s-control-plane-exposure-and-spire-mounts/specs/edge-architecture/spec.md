## ADDED Requirements
### Requirement: Default demo Kubernetes base omits host SPIRE socket mounts
The default `k8s/demo/base` deployment path SHALL NOT mount host SPIRE Workload API sockets into workloads unless SPIRE is explicitly enabled through a dedicated opt-in path.

#### Scenario: Default demo base render
- **WHEN** the default demo base is rendered without the optional SPIRE resources
- **THEN** workloads in the base do not include `hostPath` mounts for `/run/spire/sockets`
- **AND** their runtime environment does not require a SPIRE workload socket to start

#### Scenario: SPIRE opt-in render
- **WHEN** an operator explicitly enables the SPIRE-specific demo path
- **THEN** only the SPIRE-enabled workloads receive the required socket mounts and SPIRE-specific runtime wiring

### Requirement: Demo overlays keep datasvc internal by default
The shipped `k8s/demo/prod` and `k8s/demo/staging` overlays SHALL keep datasvc internal-only by default and SHALL NOT publish datasvc gRPC through an external service unless the operator explicitly opts in.

#### Scenario: Default prod overlay render
- **WHEN** the prod demo overlay is rendered as shipped
- **THEN** no external `LoadBalancer` or equivalent public-facing Service for datasvc is included by default

#### Scenario: Default staging overlay render
- **WHEN** the staging demo overlay is rendered as shipped
- **THEN** no external `LoadBalancer` or equivalent public-facing Service for datasvc is included by default
