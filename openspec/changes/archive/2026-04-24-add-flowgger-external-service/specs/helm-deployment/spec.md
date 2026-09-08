## ADDED Requirements

### Requirement: Flowgger External Service Configuration

The Helm chart SHALL provide optional external service configuration for flowgger to allow syslog/NetFlow ingestion from outside the Kubernetes cluster.

#### Scenario: External service disabled by default
- **WHEN** a user installs the Helm chart with default values
- **THEN** no external LoadBalancer service is created for flowgger
- **AND** only the internal ClusterIP service exists

#### Scenario: External service enabled with MetalLB
- **GIVEN** the user sets `flowgger.externalService.enabled: true`
- **AND** the user configures MetalLB annotations
- **WHEN** the Helm chart is deployed
- **THEN** a LoadBalancer service is created with the specified annotations
- **AND** MetalLB assigns an IP from the configured pool

#### Scenario: Custom port mapping for external syslog
- **GIVEN** the user sets `flowgger.externalService.ports.syslog.port: 30514`
- **WHEN** the external service is created
- **THEN** external port 30514 maps to container port 514
- **AND** network devices can send syslog to the external IP on port 30514

#### Scenario: Static IP assignment
- **GIVEN** the user sets `flowgger.externalService.loadBalancerIP: "192.168.1.100"`
- **WHEN** the LoadBalancer service is created
- **THEN** the load balancer SHALL attempt to acquire the specified IP
- **AND** network devices can use the predictable IP address

### Requirement: Cloud Provider Load Balancer Support

The external service configuration SHALL support cloud provider load balancers through annotations.

#### Scenario: AWS Network Load Balancer
- **GIVEN** the user configures AWS NLB annotations
- **WHEN** deployed to EKS
- **THEN** an AWS NLB is provisioned with UDP support
- **AND** external traffic reaches flowgger

#### Scenario: Generic annotations passthrough
- **GIVEN** the user sets arbitrary annotations in `flowgger.externalService.annotations`
- **WHEN** the service is created
- **THEN** all annotations are applied to the Service resource
- **AND** provider-specific features can be enabled
