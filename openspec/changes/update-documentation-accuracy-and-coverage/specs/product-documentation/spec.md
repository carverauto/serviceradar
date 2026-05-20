## ADDED Requirements

### Requirement: Documentation Accuracy Verified Against Code

Published documentation SHALL accurately describe the system as implemented. Statements
about components, configuration keys, ports, service names, stream/subject names, and
behavior SHALL match the current code.

#### Scenario: Component descriptions match the code

- **WHEN** a page describes a component, its configuration, or its data flow
- **THEN** the description matches the implementation — including the control-plane app
  name, the JetStream consumers and where they run, collector ports, and config keys
- **AND** it does not describe retired components, removed APIs, unsupported protocol
  versions, or transports the code does not provide

#### Scenario: Configuration examples are valid

- **WHEN** a page shows a configuration example
- **THEN** the example uses keys and structure that the corresponding code will accept

#### Scenario: Version and deployment references are current

- **WHEN** a page cites a chart version, image tag, or values file
- **THEN** it reflects the current chart and the values files that ship today

### Requirement: Complete Component Coverage

Every shipped, user-facing ServiceRadar component or capability SHALL have documentation —
either a dedicated page or a clearly-titled section of a related page.

#### Scenario: Each user-facing component is documented

- **WHEN** the documentation set is reviewed against the shipped components
- **THEN** network performance testing (rperf), the `serviceradar` CLI, the configuration
  system, roles and permissions, the agent configuration surface, and a web UI
  orientation are each documented

#### Scenario: No silent gaps for shipped capabilities

- **WHEN** a capability is present and enabled in the code and Helm chart
- **THEN** it is covered by the docs, or its absence is a deliberate, recorded decision
  (for example, deprecated features are not documented as if supported)

### Requirement: API Reference Reflects The Current API

The published API reference SHALL describe the API the platform actually serves.

#### Scenario: API spec matches the running API

- **WHEN** the API reference at `/api/` is viewed
- **THEN** it documents the current `web-ng` API surface (for example `/api/query`,
  `/api/devices`, `/api/admin/*`) and the real authentication scheme
- **AND** it does not document the retired `/api/pollers/*` surface

#### Scenario: API authentication is documented

- **WHEN** a reader needs to call the API
- **THEN** the docs explain how to authenticate (session and API credentials) and how to
  run an SRQL query through `/api/query`
