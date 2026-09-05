## ADDED Requirements

### Requirement: Kubernetes node alerts use the notification platform
Kubernetes node and control-plane NotReady alerts SHALL be delivered only
through `ServiceRadar.Notifications` to operator-configured channels. The
system SHALL NOT add a parallel Discord or webhook notifier for this signal.

#### Scenario: Matching route pages Discord
- **GIVEN** an enabled Discord channel and an enabled route whose
  `match_expression` equals `alert.metadata.incident_rule_name` to
  `k8s_node_not_ready`
- **WHEN** a `k8s_node_not_ready` alert is routed
- **THEN** the platform SHALL dispatch through that Discord channel
- **AND** a `NotificationDelivery` row SHALL record the attempt

#### Scenario: Unmatched node alert is audited, not silent
- **GIVEN** no enabled route matches `k8s_node_not_ready`
- **WHEN** a `k8s_node_not_ready` alert is routed
- **THEN** the platform SHALL write a delivery with
  `suppression_reason` `no_matching_route`

### Requirement: Empty-string equals is rejected on notification routes
A NotificationRoute `match_expression` SHALL NOT be saved when an `equals`
operand is an empty string. The error SHALL tell the operator that an empty
object matches every alert and that `equals: ""` matches only a blank value.

#### Scenario: Empty title equals is refused
- **WHEN** an operator saves a route with
  `{"all":[{"field":"alert.title","equals":""}]}`
- **THEN** the save SHALL fail with an actionable error naming empty-string
  `equals`

#### Scenario: Operators configure the node route through the API
- **WHEN** an authenticated caller with `notifications.routes.manage` POSTs a
  NotificationRoute whose match expression equals
  `alert.metadata.incident_rule_name` to `k8s_node_not_ready`
- **THEN** the JSON:API at `/api/v2/notification-routes` SHALL persist that
  route
- **AND** `serviceradar-cli notifications ensure-k8s-alerts` SHALL be able to
  create or update that route against a live instance

#### Scenario: Empty object still matches all
- **WHEN** an operator saves a route with match expression `{}`
- **THEN** the route SHALL be accepted
- **AND** it SHALL match every alert subject
