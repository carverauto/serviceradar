## MODIFIED Requirements
### Requirement: Helm deploys agent-gateway with edge mTLS
Helm installs SHALL deploy serviceradar-agent-gateway when enabled in values. The workload SHALL serve edge-facing gRPC over tenant-issued mTLS certificates. The gateway SHALL NOT use SPIFFE identities. Deployments that disable the gateway SHALL not render gateway workloads. Helm values SHALL allow the gateway Service to be exposed externally (LoadBalancer or NodePort) for edge agents when required.

#### Scenario: Agent-gateway is deployed by Helm
- **GIVEN** a Helm install with agent-gateway enabled
- **WHEN** the chart is rendered and applied
- **THEN** a serviceradar-agent-gateway Deployment and Service are created
- **AND** the gateway pod reaches Ready state

#### Scenario: Gateway workload omits SPIRE socket
- **GIVEN** the agent-gateway workload is deployed
- **WHEN** the pod specification is inspected
- **THEN** the SPIRE agent socket is not mounted
- **AND** the gateway serves edge gRPC using tenant-issued mTLS only

#### Scenario: Gateway disabled removes workloads
- **GIVEN** a Helm install with agent-gateway disabled
- **WHEN** the chart is rendered
- **THEN** no serviceradar-agent-gateway Deployment or Service is created

#### Scenario: Gateway Service is exposed for edge agents
- **GIVEN** a Helm install with edge gateway exposure enabled
- **WHEN** the chart is rendered
- **THEN** the agent-gateway Service is configured as LoadBalancer or NodePort
- **AND** the external port is documented or surfaced for onboarding packages
