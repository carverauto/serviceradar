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

### Requirement: A rule's incident identity excludes mutable descriptive labels
A managed StatefulAlertRule SHALL group only by values that identify the
incident subject, and SHALL carry descriptive detail through its
`event["message"]` template instead. A group key is the identity an open
incident is matched by, so a mutable label placed in `group_by` strands the
incident when it changes: the recovery event computes a different key, the
ETS lookup misses, and the incident stays open and re-pages every
`renotify_seconds`.

#### Scenario: A role change while a node is down still clears the incident
- **GIVEN** an open `k8s_node_not_ready` incident for a node whose role was
  worker when it opened
- **WHEN** the node's role label changes to control-plane while it is down and
  it later returns Ready
- **THEN** the `node.ready` event SHALL resolve that same incident

#### Scenario: The message template names the node and its role
- **WHEN** a rule sets an `event["message"]` containing `{node}` and
  `{node.role}` placeholders
- **THEN** the emitted incident event message SHALL substitute those keys from
  the triggering record
- **AND** an unresolvable placeholder SHALL be left as written rather than
  rendered as an empty value
