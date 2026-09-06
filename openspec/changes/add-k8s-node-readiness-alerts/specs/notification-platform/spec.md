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

### Requirement: Channel secret material is never served over JSON:API
A NotificationChannel's `secret_refs` SHALL NOT appear in any JSON:API
representation of that channel. The attribute holds encrypted provider
material such as a Discord webhook URL, and read access to a channel is
granted by `notifications.channels.view`, which is broader than the
`notifications.channels.manage` permission that governs writing it.

#### Scenario: Listing channels withholds secret material
- **GIVEN** a caller holding only `notifications.channels.view`
- **WHEN** the caller reads `/api/v2/notification-channels`
- **THEN** the response SHALL NOT include a `secret_refs` attribute

#### Scenario: The API offers no way to write a channel
- **WHEN** a caller POSTs to `/api/v2/notification-channels` or PATCHes a
  channel by id
- **THEN** no such route SHALL exist
- **AND** the helpers SHALL require the channel to have been created already

### Requirement: The ensure helper fails when nothing could be delivered
The ensure helpers SHALL NOT report success while the resolved channel or the
node route is disabled, and SHALL enable an existing route after updating it.
This binds `serviceradar-cli notifications ensure-k8s-alerts` and
`js/cli/ensure_k8s_node_alerts.py`; the route `update` action deliberately
does not accept `enabled`, so updating alone leaves a disabled route disabled.

#### Scenario: Disabled channel stops the run
- **GIVEN** the named Discord channel exists but is disabled
- **WHEN** an operator runs the ensure helper
- **THEN** the helper SHALL fail with an actionable error and SHALL NOT print
  a success line

#### Scenario: Disabled route is re-enabled
- **GIVEN** a `k8s-node-not-ready` route that exists and is disabled
- **WHEN** an operator runs the ensure helper
- **THEN** the helper SHALL enable that route before reporting success

### Requirement: The node probe pages before it clears
The synthetic node probe SHALL open the incident and clear it in two separate
API calls. `POST /api/v2/alerts/k8s-node-not-ready-test` SHALL publish only
`node.not_ready`, and `POST /api/v2/alerts/k8s-node-ready-test` SHALL publish
only the matching `node.ready`. A single call SHALL NOT publish both, because
concurrent evaluation of the two events either resolves the alert before its
queued routing job runs - dispatch then skips a resolved alert - or clears an
incident that has not yet opened.

#### Scenario: Firing the probe leaves the incident open
- **WHEN** a caller posts to `/api/v2/alerts/k8s-node-not-ready-test`
- **THEN** only a `node.not_ready` event SHALL be published
- **AND** the resulting incident SHALL remain open until the clear is posted

#### Scenario: Clearing the probe is a separate call
- **GIVEN** an open probe incident for the synthetic node
- **WHEN** a caller posts to `/api/v2/alerts/k8s-node-ready-test` with the
  same `cluster_id`, `node` and `role`
- **THEN** a `node.ready` event SHALL be published for that group

#### Scenario: One invocation cannot both fire and clear
- **WHEN** an operator passes both `--fire-test` and `--clear-test` to an
  ensure helper
- **THEN** the helper SHALL fail with an actionable error before contacting
  the instance, naming the two-step order

### Requirement: The ensure helpers touch only the node route they own
The ensure helpers SHALL create or update only the `k8s-node-not-ready` route,
its escalation policy, and that policy's first step, and SHALL NOT disable,
delete, or otherwise mutate any other operator-owned NotificationRoute. A
disabled route is skipped by the Router entirely and nothing re-enables it, so
a sweep run by an idempotent "ensure" command would silently stop unrelated
paging.

#### Scenario: Unrelated routes survive an ensure run
- **GIVEN** an enabled route unrelated to `k8s_node_not_ready`
- **WHEN** an operator runs an ensure helper
- **THEN** that route SHALL remain enabled and unmodified
