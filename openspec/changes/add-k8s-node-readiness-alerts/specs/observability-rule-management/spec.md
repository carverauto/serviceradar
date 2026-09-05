## ADDED Requirements

### Requirement: Seeded Kubernetes node NotReady incident rule
The system SHALL seed a managed StatefulAlertRule named `k8s_node_not_ready`
that opens one incident per cluster node when a `node.not_ready` event is
observed and clears that incident when a `node.ready` event is observed for
the same node.

#### Scenario: Worker NotReady opens a critical incident
- **WHEN** a `node.not_ready` event arrives for a worker node
- **THEN** the engine SHALL open a critical alert whose metadata
  `incident_rule_name` is `k8s_node_not_ready`
- **AND** the alert title SHALL identify the node as a worker

#### Scenario: Control-plane NotReady is distinguished
- **WHEN** a `node.not_ready` event arrives for a control-plane node
- **THEN** the engine SHALL open a critical alert for rule `k8s_node_not_ready`
- **AND** the alert title SHALL identify the node as control-plane

#### Scenario: Ready recovery clears the incident
- **WHEN** a `node.ready` event arrives for a node with an open
  `k8s_node_not_ready` incident
- **THEN** the engine SHALL resolve that incident

#### Scenario: Operator disable survives reseed
- **WHEN** an operator disables `k8s_node_not_ready`
- **AND** rule seeding runs again
- **THEN** the rule SHALL remain disabled
