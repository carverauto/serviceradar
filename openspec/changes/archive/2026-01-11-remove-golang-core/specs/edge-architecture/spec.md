## MODIFIED Requirements

### Requirement: Core Service Architecture

The platform SHALL operate with a single Elixir-based core service (core-elx) as the control plane.

The core-elx service SHALL:
- Handle REST API requests on port 8090
- Handle gRPC communication with gateways on port 50052
- Expose metrics on port 9090
- Participate in the ERTS cluster with web-ng and agent-gateway nodes
- Manage authentication via JWT/JWKS
- Process alerts and webhook notifications
- Coordinate device and service registration

The platform SHALL NOT include or reference the deprecated golang-based serviceradar-core service in:
- Production deployments
- Docker compose configurations
- Kubernetes manifests
- Helm charts
- Installation documentation
- Architecture diagrams

#### Scenario: Core-elx is the sole control plane
- **WHEN** the platform is deployed
- **THEN** only core-elx handles control plane responsibilities
- **AND** no golang core containers or processes are running

#### Scenario: Documentation reflects current architecture
- **WHEN** a user reads architecture documentation
- **THEN** all diagrams and descriptions reference core-elx
- **AND** no references to deprecated golang core exist

