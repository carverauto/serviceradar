## ADDED Requirements

### Requirement: Notifications Settings Catalog Entry

The notification platform SHALL be reachable from exactly ONE entry in
`ServiceRadarWebNGWeb.Settings.Catalog`, filed under the existing
`:sys_alerts` parent-group in the `:system` category, at route
`/settings/notifications`. The entry MUST satisfy every structural rule the
catalog gate (`test/phoenix/settings/catalog_test.exs`) enforces: a unique
`id`, a unique `route`, a unique `(category, id)` pair, a non-empty
`description`, `has_own_stats: false` (Cluster Status is the only view allowed
to be `true`), a `live_view` that the Phoenix router actually reaches at that
path, and a `permission` string that is a member of
`ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`.

The tabs of the notification surface (Channels, Routes and Escalation,
Silences, Providers, Delivery Log) SHALL NOT be registered as separate catalog
views. They are nested paths under the single entry and MUST resolve to it via
`Catalog.view_for_path/1` longest-prefix matching, so no two views can own an
identical match prefix.

#### Scenario: The catalog gate passes with the new entry

- **WHEN** `ServiceRadarWebNGWeb.Settings.CatalogTest` runs after the entry is added
- **THEN** every structural assertion passes: the `permission` key is present in
  `RBAC.Catalog.permission_keys/0`, the `route` is unique, the `(category, id)`
  pair is unique, `parent_group` is `:sys_alerts` and belongs to the `:system`
  category, `description` is a non-empty binary, `has_own_stats` is `false`, and
  the router resolves `/settings/notifications` to the declared `live_view`

#### Scenario: A permission key not in the RBAC catalog fails CI

- **WHEN** the entry declares a `permission` value that
  `RBAC.Catalog.permission_keys/0` does not contain
- **THEN** the catalog test fails in CI with the offending view id and permission
- **AND** the failure occurs in the test suite, never at runtime in production

#### Scenario: A nested tab path resolves to the single catalog entry

- **WHEN** an operator navigates to `/settings/notifications/deliveries`
- **THEN** `Catalog.view_for_path/1` returns the single notifications view
- **AND** the settings shell highlights that one view and renders its
  breadcrumbs as Settings > System > Notifications
- **AND** no second catalog view claims the `/settings/notifications` prefix

#### Scenario: A scope without the entry permission does not see the view

- **WHEN** `Catalog.visible_views/2` is called for the `:system` category with a
  scope that holds no notification permissions
- **THEN** the notifications view is absent from the returned list and from
  `Catalog.palette_index/1`

### Requirement: Notification Settings Tab Shell

The `/settings/notifications` LiveView SHALL render five tabs -- Channels,
Routes and Escalation, Silences, Providers, and Delivery Log -- using
`ServiceRadarWebNGWeb.UIComponents.ui_tabs/1`. The active tab MUST be encoded in
the URL as a nested path segment under `/settings/notifications` and driven
through `handle_params/3` plus `push_patch/2`, so a tab is deep-linkable,
survives a page reload, and is shareable.

Each tab SHALL declare the RBAC permission it requires. A tab whose permission
the current scope lacks MUST NOT be rendered, and direct navigation to that
tab's path MUST redirect to a permitted tab with an error flash rather than
rendering an empty or partially populated tab.

#### Scenario: Deep link to a tab

- **WHEN** an operator loads `/settings/notifications/routes` directly
- **THEN** the Routes and Escalation tab renders as the active tab
- **AND** reloading the page returns to the same tab

#### Scenario: Tab hidden without permission

- **WHEN** a scope holds `notifications.channels.view` but not
  `notifications.deliveries.view`
- **THEN** the Delivery Log tab is not rendered
- **AND** navigating directly to `/settings/notifications/deliveries` redirects
  to the Channels tab with an error flash
- **AND** no delivery data is loaded or sent to the client

### Requirement: Notification Channel Management

The Channels tab SHALL list every `NotificationChannel` with its `name`,
provider `display_name`, `provider_type`, `execution_route`, `enabled` state,
`health`, `last_success_at`, `last_failure_at`, `last_error`,
`rate_limit_per_minute`, `max_attempts`, `fallback_channel_id`, and
`fail_closed`. It SHALL support creating a channel, editing a channel, and
disabling a channel.

`max_attempts` is a channel attribute whose default is supplied by the provider.
The form MUST render it as an editable bounded integer, MUST show the provider
default when the operator has not overridden it, and MUST state that a delivery
stays `:pending` with `next_attempt_at` set until `max_attempts` is exhausted,
at which point it becomes terminal `:failed`.

Disabling a channel MUST set `enabled` to false and MUST NOT delete the
channel's `NotificationDelivery` history. Deleting a channel that has delivery
history MUST be refused or MUST be presented as an archive that preserves the
history, so the Delivery Log remains answerable.

Channel health SHALL be rendered as a labelled `ui_badge` derived from `health`,
`last_success_at`, and `last_failure_at`, and MUST expose `last_error` on demand
without requiring a database round trip per row.

The list SHALL be rendered with LiveView streams and a server-side limit so a
deployment with more than 100 channels does not load the whole table into
socket assigns.

#### Scenario: Operator creates a channel

- **WHEN** an operator holding `notifications.channels.manage` submits a valid
  new channel with a provider, a name, and a config that validates against the
  provider `config_schema`
- **THEN** the channel is created with `execution_route` defaulting to
  `:control_plane`
- **AND** the new row appears in the streamed list without a full page reload

#### Scenario: Read-only operator cannot mutate

- **WHEN** a scope holds `notifications.channels.view` but not
  `notifications.channels.manage`
- **THEN** the Channels tab renders the list
- **AND** create, edit, disable, and test controls are not rendered
- **AND** a forged `save_channel` event is rejected in `handle_event` with no
  state change and an error flash

#### Scenario: Disabling preserves history

- **WHEN** an operator disables a channel that has 400 delivery rows
- **THEN** the channel `enabled` becomes false
- **AND** the 400 delivery rows remain queryable in the Delivery Log
- **AND** subsequent routing to that channel records deliveries with
  `suppression_reason: :channel_disabled` rather than dropping silently

#### Scenario: Failover target is validated in the UI

- **WHEN** an operator sets `fallback_channel_id` to a disabled channel, or to a
  channel that forms a fallback cycle, or sets `fail_closed` true while a
  fallback is also selected
- **THEN** the form surfaces an inline warning naming the specific problem
- **AND** the warning is shown before save, not only after a delivery fails

### Requirement: Provider-Driven Channel Configuration Form

A channel's configuration form SHALL be rendered from the selected
`NotificationProvider.config_schema` by the schema-driven renderer
(`ServiceRadarWebNGWeb.PluginConfigForm` and its successors), not by
per-provider handwritten markup. Adding a `:declarative` provider MUST therefore
produce a working configuration form with no web-ng code change.

The form MUST offer only the `execution_route` values present in the provider's
`supported_routes`. Selecting `:edge_agent` MUST require an `agent_uid`. The
channel `partition_id` MUST NOT be an operator-editable field; it is force-bound
server-side from the agent binding.

Provider-supplied content is data, never markup. The renderer MUST reject a
`config_schema` or display contract carrying `html`, `raw_html`, `javascript`,
`js`, `component`, `component_ref`, `live_view`, `react`, or `ui_code` keys, and
MUST NOT pass any provider-supplied string through `raw/1`.

#### Scenario: Declarative provider renders a form with no code change

- **WHEN** a `:declarative` provider is uploaded whose `config_schema` declares a
  string `webhook_url`, an enum `severity_floor`, and a boolean `include_links`
- **THEN** the channel form renders a text input, a select, and a checkbox
- **AND** no module under `elixir/web-ng` was modified to make that happen

#### Scenario: Unsupported route is not offerable

- **WHEN** a provider declares `supported_routes: [:control_plane]`
- **THEN** the `execution_route` control offers only `:control_plane`
- **AND** a submitted form carrying `execution_route: "edge_agent"` is rejected
  server-side with a validation error

#### Scenario: Provider markup is refused

- **WHEN** an uploaded provider definition includes a `ui_code` or `component_ref`
  key in its config schema or display contract
- **THEN** the provider fails validation and is not activated
- **AND** the operator sees the offending key path in the error list

### Requirement: Channel Secret Fields Never Echo Stored Values

Fields marked `secretRef` in the provider `config_schema` SHALL render as empty
password inputs. The UI MUST NEVER render a stored secret value, a decrypted
credential, or any value resolved through `Credentials.SecretBroker`. The only
secret-adjacent value the UI may display is the opaque `secretref:` handle
itself.

When a secret is already stored, the input MUST render with an empty `value`
and a placeholder indicating that leaving it blank keeps the existing secret.
Submitting the form with the field blank MUST preserve the stored
`secret_refs` entry unchanged.

#### Scenario: Editing a channel with a stored token

- **WHEN** an operator opens the edit form for a channel whose config holds
  `bot_token` as a `secretref:` handle
- **THEN** the `bot_token` input renders as `type="password"` with an empty value
- **AND** the placeholder reads that leaving it blank keeps the existing secret
- **AND** the rendered HTML contains the `secretref:` handle at most, never the
  resolved token

#### Scenario: Blank submission keeps the secret

- **WHEN** the operator changes only the channel `name` and saves with the secret
  field left blank
- **THEN** the stored `secret_refs` entry is unchanged
- **AND** no secret value is written to the LiveView assigns, the DOM, or the
  server logs

### Requirement: Channel Test Send Before Save

The Channels tab SHALL provide a test send that is available BEFORE a channel is
saved, using the configuration currently in the form -- including a
newly-entered secret that has not yet been persisted. Test send MUST be gated on
`notifications.test.send`.

The result MUST be displayed inline and MUST include the outcome, the provider's
error class and message on failure, and the reason when the attempt is refused
by an outbound policy. Any operator-supplied outbound URL exercised by a test
MUST be validated by `Palisade.OutboundURLPolicy.validate_https_public_url/2`
and the rejection reason surfaced to the operator.

A test send MUST respect the channel `rate_limit_per_minute` and MUST NOT be
attributed to a real alert. Any `NotificationDelivery` row a test writes MUST
carry `is_test: true`, MUST be visually distinguished from alert-driven
deliveries wherever it is recorded, and MUST NOT be counted in any alert
delivery or notification count the UI displays.

#### Scenario: Test before first save

- **WHEN** an operator fills in a new Slack channel form, enters a bot token, and
  clicks Send test without saving
- **THEN** the test message is dispatched using the in-form configuration
- **AND** no `NotificationChannel` row is created by the test
- **AND** the outcome is rendered inline

#### Scenario: SSRF-guarded URL is refused with a reason

- **WHEN** a test targets a webhook URL that resolves to a private address or is
  not HTTPS
- **THEN** `Palisade.OutboundURLPolicy.validate_https_public_url/2` rejects it
- **AND** the UI shows the specific rejection reason rather than a generic failure

#### Scenario: Test send without permission

- **WHEN** a scope lacking `notifications.test.send` triggers the `test_channel`
  event
- **THEN** the event is refused in `handle_event` with an error flash
- **AND** no outbound request is made

### Requirement: Notification Route Authoring

The Routes and Escalation tab SHALL list every `NotificationRoute` ordered by
`priority` ascending, showing `name`, `enabled`, `priority`, a human-readable
summary of `match_expression`, the linked `NotificationEscalationPolicy`, the
linked `NotificationSchedule`, `throttle_seconds`, `group_wait_seconds`,
`group_interval_seconds`, `dedupe_key_template`, and `continue`.

Routes SHALL be authored through a predicate builder that composes
`match_expression` from field / operator / value rows with explicit AND and OR
grouping. Selectable field names MUST come from an enumerated server-side
whitelist; the builder MUST NOT call `String.to_atom/1` or
`String.to_existing_atom/1` on any operator-supplied field, operator, or value.

The UI SHALL make `continue` semantics legible: it MUST show, for a supplied or
selected sample alert, which routes match, in priority order, and exactly where
evaluation stops because a matching route has `continue` set to false.

#### Scenario: Priority ordering is explicit and stable

- **WHEN** an operator reorders routes
- **THEN** each route's `priority` is persisted such that the displayed order is
  reproducible after a reload
- **AND** the evaluation order shown in the UI matches the order the routing
  engine uses

#### Scenario: Continue evaluation preview

- **WHEN** an operator previews routing for a sample alert against four routes
  where the second matching route has `continue: false`
- **THEN** the preview lists both matching routes in priority order
- **AND** marks the second as terminal
- **AND** shows that the third and fourth routes were not evaluated

#### Scenario: Predicate fields are whitelisted

- **WHEN** a crafted form submission supplies a field name outside the enumerated
  whitelist
- **THEN** the submission is rejected with a validation error
- **AND** no atom is created from the supplied string

### Requirement: Escalation Policy Authoring With Fan-Out

The Routes and Escalation tab SHALL provide an editor for
`NotificationEscalationPolicy` (`name`, `repeat_count`,
`repeat_interval_seconds`, `resolve_notifies`) and its ordered
`NotificationEscalationStep` rows.

Each step SHALL expose `step_number`, `delay_seconds`, a `condition` selector
limited to `:always` and `:if_unacknowledged`, and a MULTI-SELECT of
`channel_ids` -- the fan-out set. A step MUST require at least one channel.
Adding, removing, or reordering steps MUST renumber `step_number` contiguously
starting at 1.

The editor SHALL render the policy as a timeline showing cumulative offsets
(for example `t+0`, `t+5m`, `t+15m`) with the channel set at each step, so
fan-out (a set of channels in one step) is visually distinct from escalation (a
later step gated on non-acknowledgement).

A step referencing a disabled channel, a channel whose provider is disabled, or
a channel that no longer exists MUST be flagged in the editor and in the list.

#### Scenario: Fan-out within a step

- **WHEN** an operator adds step 1 with `delay_seconds: 0`, `condition: :always`,
  and channels `[Slack #noc, Email noc@]`
- **THEN** the timeline renders one step at `t+0` containing both channels
- **AND** the step is not rendered as two sequential escalations

#### Scenario: Steps renumber contiguously

- **WHEN** an operator deletes step 2 of a four-step policy
- **THEN** the remaining steps are renumbered 1, 2, 3
- **AND** the displayed cumulative offsets are recomputed from the new order

#### Scenario: Step with no channel is rejected

- **WHEN** an operator saves a step with an empty channel selection
- **THEN** the save is refused with an inline validation error naming the step

#### Scenario: Disabled channel in a step is flagged

- **WHEN** a channel referenced by step 3 is disabled
- **THEN** the policy editor and the policy list show a warning identifying the
  step and the channel
- **AND** the warning states that deliveries to that step will record
  `suppression_reason: :channel_disabled`

### Requirement: Edge-Route Escalation Safety Warning

The UI SHALL compute, for each `NotificationEscalationPolicy`, the set of
channels reachable across all steps including one hop through
`fallback_channel_id`. When EVERY reachable channel has `execution_route` set to
`:edge_agent` and is bound to a `partition_id` that can be the partition of the
alert source, the UI MUST display a warning stating that this configuration
cannot deliver a site-down page, because `ServiceRadar.Edge.AgentCommandBus` is
at-most-once with no store-and-forward and core is the component that detects
the darkness.

The warning MUST also fire when the sole reachable fallback is itself an
`:edge_agent` channel in the same partition, and when a channel with
`fail_closed: true` has `:edge_agent` as its only route.

The warning SHALL be non-blocking -- an operator may deliberately save such a
policy -- but it MUST persist on the policy list and on any route bound to the
policy, not only inside the editor at save time. The remediation text MUST name
the two supported fixes: add a `:control_plane` channel to a step, or set
`fallback_channel_id` to a `:control_plane` channel.

#### Scenario: Edge-only policy is warned

- **WHEN** an operator saves a policy whose only channels across all steps are
  `:edge_agent` channels bound to partition `site-a`, with no fallback
- **THEN** a warning is displayed stating that a site-down page for `site-a`
  cannot be delivered by this policy
- **AND** the warning names adding a `:control_plane` channel or a
  `:control_plane` fallback as the remediation
- **AND** the save is still permitted

#### Scenario: Warning persists outside the editor

- **WHEN** the operator navigates away and returns to the Routes and Escalation
  list
- **THEN** the warning indicator is present on the policy row and on every route
  bound to that policy

#### Scenario: Control-plane fallback clears the warning

- **WHEN** the operator sets `fallback_channel_id` on the edge channel to a
  `:control_plane` channel
- **THEN** the warning is no longer displayed for that policy

#### Scenario: fail_closed edge channel is warned

- **WHEN** a step's only channel is `:edge_agent` with `fail_closed: true`
- **THEN** the warning states that failover is disabled by `fail_closed` and the
  page will be lost when the agent is offline

### Requirement: Silence Authoring and Cancellation

The Silences tab SHALL support creating, editing, and cancelling
`NotificationSilence` records. A silence MUST carry `matchers`, `starts_at`,
`ends_at`, and a NON-EMPTY `comment`. The comment is mandatory: a silence
without a stated reason MUST be refused.

`created_by_user_id` MUST be derived server-side from the authenticated scope
and MUST NOT be accepted from form parameters. The silence `state`
(`:scheduled`, `:active`, `:expired`, `:cancelled`) SHALL be rendered as a
labelled badge.

Cancelling a silence MUST be an explicit action that records the acting user and
MUST leave the cancelled silence visible in the list rather than removing it,
so the audit trail survives.

Before saving, the editor SHALL preview what the matchers currently match, so an
operator can see the blast radius of a silence prior to committing it.

#### Scenario: Comment is required

- **WHEN** an operator submits a silence with matchers and a window but no comment
- **THEN** the save is refused with an inline validation error on the comment field

#### Scenario: Creator is server-derived

- **WHEN** a crafted submission includes a `created_by_user_id` for another user
- **THEN** the supplied value is ignored and the authenticated user's id is stored

#### Scenario: Cancellation is auditable

- **WHEN** an operator cancels an active silence
- **THEN** the silence `state` becomes `:cancelled`
- **AND** the row remains listed with the cancelling actor and timestamp
- **AND** suppression for matching alerts stops on the next dispatch evaluation

#### Scenario: Blast-radius preview

- **WHEN** an operator enters matchers that would match 312 current alerts
- **THEN** the editor shows the matched count and a bounded sample before save

### Requirement: Currently Suppressed Visibility

The Silences tab SHALL show what is currently suppressed, not only what silences
exist. It MUST enumerate active suppression by `suppression_reason` across every
source the platform evaluates -- `:device_out_of_service`, `:silence`,
`:schedule`, `:snoozed`, `:throttled`, `:acknowledged`, `:channel_disabled`,
`:no_matching_route`, and the reserved `:dependency` -- with a count per reason
over a bounded recent window.

Each reason MUST link to the Delivery Log pre-filtered by that
`suppression_reason`, so an operator moves from "something is being suppressed"
to the individual suppressed deliveries in one click.

For each active silence, the UI SHALL show the number of deliveries suppressed
with `suppression_reason: :silence` attributable to that silence.

#### Scenario: Suppression summary is enumerable

- **WHEN** an operator opens the Silences tab while a maintenance window is active
  and three devices are marked out of service
- **THEN** the summary lists `:schedule` and `:device_out_of_service` with counts
- **AND** each entry links to the Delivery Log filtered by that reason

#### Scenario: Per-silence attribution

- **WHEN** an active silence has suppressed 42 deliveries
- **THEN** its row shows 42 and links to those delivery rows

### Requirement: Provider Catalog Browsing

The Providers tab SHALL list every `NotificationProvider` with `provider_key`,
`display_name`, `provider_type` (`:native`, `:declarative`, `:wasm_plugin`,
`:stream`), `source` (`:first_party`, `:uploaded`, `:plugin`), state
(`:draft`, `:active`, `:disabled`), `capabilities`, `payload_formats`,
`supported_routes`, and `template_version`.

`:native`, `:declarative`, and `:wasm_plugin` are the THREE extensibility tiers
an operator can author against. `:stream` is a built-in provider type and is NOT
an extensibility tier, because an operator cannot author one; the UI MUST label
it as built-in and MUST NOT offer it in the upload flow. The seeded first-party
catalog MUST include the managed `:stream` provider row alongside slack,
discord, webhook, and email.

The UI MUST make the three provenance classes distinguishable at a glance:
first-party managed providers, operator-uploaded declarative definitions, and
plugin-backed providers. For a provider with `managed: true`, the UI MUST
indicate that its managed fields are reconciled across upgrades by
`template_version` and `template_fingerprint`, and MUST indicate which fields an
operator edit will preserve.

Disabling a provider MUST first show which channels become unusable, and MUST
state that deliveries to those channels will record
`suppression_reason: :channel_disabled`.

#### Scenario: Provenance is visible

- **WHEN** an operator opens the Providers tab with the seeded first-party
  catalog, one uploaded declarative provider, and one plugin-backed provider
- **THEN** each row shows its `source` and `provider_type`
- **AND** the managed first-party rows carry a managed indicator with the
  `template_version`

#### Scenario: The stream provider is listed as built-in

- **WHEN** an operator opens the Providers tab on a freshly seeded deployment
- **THEN** the managed `:stream` provider is listed alongside slack, discord,
  webhook, and email
- **AND** it is labelled a built-in provider type rather than an authorable tier
- **AND** the upload flow offers only `:declarative` as an authorable tier

#### Scenario: Disabling a provider shows the blast radius

- **WHEN** an operator disables a provider used by five channels
- **THEN** a confirmation lists the five channels by name
- **AND** states that their deliveries will be recorded as
  `suppression_reason: :channel_disabled`
- **AND** the disable proceeds only on explicit confirmation

#### Scenario: Provider management requires permission

- **WHEN** a scope holds `notifications.channels.view` but not
  `notifications.providers.manage`
- **THEN** the Providers tab renders read-only
- **AND** upload, activate, disable, and rollback controls are not rendered

### Requirement: Declarative Provider Upload, Validation, and Versioning

The Providers tab SHALL allow an operator holding
`notifications.providers.manage` to upload a `:declarative` provider definition
document and to add a new notification provider WITHOUT a code change or a
release.

An upload MUST be validated before it can be activated. Validation MUST cover:
the config schema against `Plugins.ConfigSchema`; the request template document
against the declarative template validator; the restricted substitution
contract of D9 -- whitelisted variable paths and the fixed filter set `upper`,
`lower`, `truncate`, `json`, `url_encode`, `iso8601`, `default`, with no EEx and
no arbitrary code; and rejection of the prohibited markup keys `html`,
`raw_html`, `javascript`, `js`, `component`, `component_ref`, `live_view`,
`react`, `ui_code`. Every validation failure MUST be reported with the location
inside the document that caused it.

Statically resolvable outbound URLs in the template MUST be validated at save by
`Palisade.OutboundURLPolicy.validate_https_public_url/2`.

An uploaded definition MUST land in the `:draft` state as a NEW
`template_version`. Activation is a separate explicit action. Prior versions
MUST be retained, viewable, and roll-back-able. An uploaded provider MUST carry
`source: :uploaded` and MUST NOT be able to declare `implementation_module` or
`plugin_package_id`.

#### Scenario: Upload, validate, activate

- **WHEN** an operator uploads a valid Mattermost declarative definition
- **THEN** it is stored as `template_version` 1 in `:draft` with
  `source: :uploaded`
- **AND** it becomes selectable for new channels only after the operator
  activates it

#### Scenario: Invalid template is reported precisely

- **WHEN** an uploaded definition uses an unknown filter `md5` and references an
  unwhitelisted variable path
- **THEN** validation fails
- **AND** both problems are listed with the path inside the document
- **AND** the provider is not activated

#### Scenario: Upload cannot claim a native module

- **WHEN** an uploaded definition sets `implementation_module`
- **THEN** the upload is rejected
- **AND** the error states that `:native` providers are resolved from a
  compile-time allowlist and cannot be uploaded

#### Scenario: Rollback to a prior version

- **WHEN** version 3 of an uploaded provider breaks delivery and the operator
  rolls back to version 2
- **THEN** version 2 becomes the active definition
- **AND** version 3 remains viewable in the version history

### Requirement: Delivery Log Answers Why Was I Not Paged

The Delivery Log tab SHALL be the operator surface that answers "why was I not
paged?". It MUST list `NotificationDelivery` rows in EVERY state, explicitly
including `:suppressed` and `:skipped`, never only successful sends.

The log MUST be filterable by alert, channel, delivery `state`, and
`suppression_reason`, and SHOULD additionally filter by route, escalation policy
step, `execution_route`, `payload_format`, `provider_version`, `is_test`, and
time range. Filters MUST be reflected in the URL so a filtered view is
shareable.

The `suppression_reason` filter MUST offer every reason the platform records,
including `:no_matching_route`, so an alert that matched zero enabled routes is
reachable through the same audit path as a silenced or throttled one instead of
being invisible.

Each row MUST show `state`, `suppression_reason`, channel, route, policy and
`step_number`, `attempt_count`, the `max_attempts` bound it is measured against,
`next_attempt_at`, `error_class`, `error_message`, `external_correlation_id`,
`execution_route`, `agent_uid`, `command_id`, `payload_format`,
`provider_version`, `is_test`, `originating_delivery_id`, and the `queued_at` /
`started_at` / `finished_at` timestamps.

`payload_format` MUST be displayed as the format actually negotiated and
rendered for that delivery, and `provider_version` MUST identify the provider
definition version that rendered it, so a payload regression is attributable to
a specific provider version rather than to the provider in general.

`originating_delivery_id` MUST render as a link to the delivery that failed over
into this one, so an operator can walk a failover chain from the original
attempt to the delivery that finally succeeded or failed. A row that is itself a
failover target MUST be labelled as such rather than presented as an independent
dispatch.

Rows with `is_test: true` MUST be visually distinguished from alert-driven
deliveries, MUST be filterable and excludable, and MUST NOT be counted in any
alert-level delivery or notification count the UI displays.

Because `Jobs.AlertsRetentionWorker` hard-deletes resolved and suppressed alerts
after a default of three days while deliveries are retained longer, the log MUST
render from `alert_snapshot` when the referenced alert row no longer exists,
rather than rendering a broken link or an empty row.

The alert detail page MUST deep-link into this log filtered to that alert.

#### Scenario: Suppressed delivery explains itself

- **WHEN** an alert produced no page because an active silence matched
- **THEN** the Delivery Log contains a row for that alert and channel with
  `state: :suppressed` and `suppression_reason: :silence`
- **AND** the row links to the silence that caused it

#### Scenario: Filter by suppression reason

- **WHEN** an operator filters by `suppression_reason: :throttled`
- **THEN** only throttled deliveries are listed
- **AND** the filter is encoded in the URL and survives a reload

#### Scenario: Delivery outlives its alert

- **WHEN** a delivery row's alert was hard-deleted by the retention worker
- **THEN** the row still renders the alert summary, severity, and subject from
  `alert_snapshot`
- **AND** the alert link is rendered as unavailable rather than broken

#### Scenario: Retry state is legible

- **WHEN** a delivery has failed twice and is scheduled to retry
- **THEN** the row shows `state: :pending` with `attempt_count: 2`, the
  `error_class`, `next_attempt_at`, and the `max_attempts` bound
- **AND** it is not displayed as `:failed`, which is reserved for the terminal
  case of a non-retryable failure or exhausted `max_attempts`
- **AND** distinguishes transport retry from a later escalation step

#### Scenario: Unrouted alert is visible

- **WHEN** an alert matches no enabled `NotificationRoute`
- **THEN** the Delivery Log contains a row for that alert with
  `state: :suppressed` and `suppression_reason: :no_matching_route`
- **AND** filtering by `:no_matching_route` lists it

#### Scenario: Failover chain is walkable

- **WHEN** a delivery to a primary channel exhausts `max_attempts` and fails
  over to `fallback_channel_id`
- **THEN** the failover row carries `originating_delivery_id` pointing at the
  primary row
- **AND** the two rows are linked so the chain is legible from either end
- **AND** the failover row is labelled as a failover rather than as an
  independent dispatch

#### Scenario: Rendered format and provider version are attributable

- **WHEN** a Slack delivery was rendered as `:slack_blocks` by provider
  definition version 3
- **THEN** the row shows `payload_format: :slack_blocks` and
  `provider_version: 3`
- **AND** the log can be filtered to that `provider_version` to scope a payload
  regression

#### Scenario: Test deliveries are marked and uncounted

- **WHEN** an operator sends three test messages to a channel and then views an
  alert that produced one real delivery on that channel
- **THEN** the alert reports one notification, not four
- **AND** the three `is_test: true` rows are visible in the Delivery Log,
  visually distinguished, and excludable by filter

### Requirement: Delivery Log Redaction and Payload Handling

The Delivery Log MUST NOT display a rendered notification payload verbatim. It
SHALL display a redacted payload summary and the `rendered_payload_digest`.

Every delivery-derived field displayed to an operator -- including
`result_summary`, `error_message`, and any provider response excerpt -- MUST
pass `ActionRedaction` under policy `northbound-action-redaction-v1` before it
is persisted for display or rendered.

No delivery-derived content may be rendered through `raw/1`. Channel
`secret_refs`, resolved credentials, and capability-link tokens MUST NEVER
appear in the log; acknowledgement tokens are persisted as sha256 only and the
UI MUST NOT display or reconstruct them.

#### Scenario: Payload is summarised, not dumped

- **WHEN** an operator opens a delivery row for a Slack message
- **THEN** the UI shows a redacted summary and the `rendered_payload_digest`
- **AND** does not show the full rendered JSON body

#### Scenario: Provider error containing a secret is redacted

- **WHEN** a provider returns an error string that embeds a bearer token
- **THEN** the stored and displayed `error_message` has the token redacted by
  `northbound-action-redaction-v1`

#### Scenario: No raw rendering of untrusted content

- **WHEN** an alert title or provider response contains HTML or script markup
- **THEN** it is rendered escaped as text
- **AND** no `raw/1` call is present on any delivery-derived assign

### Requirement: Alert Detail Acknowledgement Controls

`ServiceRadarWebNGWeb.AlertLive.Show`, which is presently read-only, SHALL gain
operator controls for Acknowledge, Snooze with a duration, Resolve, and
Suppress. These MUST be gated on the existing RBAC permission
`observability.alerts.manage` (catalogued as "Acknowledge and resolve alerts"),
which today has no user interface.

Authorization MUST be checked in `mount/3` AND re-checked inside EVERY
`handle_event/3` that mutates state; a permission check at mount alone is
insufficient.

Snooze duration MUST be selected from an enumerated, server-validated set with a
bounded custom option, and MUST be parsed as an integer number of seconds. The
UI MUST NOT call `String.to_atom/1` on the duration, the action name, or any
other user-supplied value.

An acknowledgement performed here MUST set `acknowledged_by_user_id` as a real
foreign key to `ServiceRadar.Identity.User`, and MUST record a
`NotificationAcknowledgement` with `actor_kind: :platform_user` and
`source: :ui`.

Controls MUST reflect the `Alert` state machine: an action the current state
does not permit MUST be disabled with an explanation rather than failing after
the click. The UI MUST NOT show an optimistic state change; it renders the new
state only after the action returns, and on failure restores the control and
shows the error.

#### Scenario: Acknowledge from the alert detail page

- **WHEN** an operator holding `observability.alerts.manage` clicks Acknowledge
- **THEN** the alert transitions to acknowledged
- **AND** `acknowledged_by_user_id` is set to the acting user's id
- **AND** a `NotificationAcknowledgement` row is written with
  `actor_kind: :platform_user`, `source: :ui`
- **AND** pending escalation for that alert stops, recorded as
  `suppression_reason: :acknowledged`

#### Scenario: Snooze with a duration

- **WHEN** an operator selects Snooze 1h
- **THEN** the alert takes the `:snooze` transition with `snooze_until` one hour
  ahead
- **AND** dispatches during that window are recorded with
  `suppression_reason: :snoozed`

#### Scenario: Permission re-checked on every event

- **WHEN** a scope lacking `observability.alerts.manage` sends a crafted
  `acknowledge` event to a mounted alert detail LiveView
- **THEN** the event is refused inside `handle_event`
- **AND** no alert state changes and no acknowledgement row is written

#### Scenario: Disallowed transition is disabled, not failed

- **WHEN** an alert is already resolved
- **THEN** Acknowledge and Snooze render disabled with an explanation
- **AND** clicking them produces no event and no error toast churn

#### Scenario: Notification history is reachable from the alert

- **WHEN** an operator views an alert detail page
- **THEN** a control links to the Delivery Log filtered to that alert
- **AND** the page shows whether any notification was sent, suppressed, or is
  pending retry

### Requirement: Alert List Bulk Acknowledge and Snooze

`ServiceRadarWebNGWeb.AlertLive.Index` SHALL support selecting multiple alerts
and applying Acknowledge or Snooze to the selection, gated on
`observability.alerts.manage`.

The selection size MUST be bounded. Every alert id in a submitted selection MUST
be re-authorized and re-validated server-side against the viewer's scope and the
active filter; client-supplied ids MUST NOT be trusted as evidence of
visibility.

A bulk action MUST report per-alert outcomes: the number that succeeded, the
number that failed, and an enumeration of the failures with their reasons. A
partial failure MUST NOT be reported as success. Each successfully actioned
alert MUST record its own `NotificationAcknowledgement`.

#### Scenario: Bulk acknowledge with partial failure

- **WHEN** an operator selects 20 alerts and 3 have already been resolved
- **THEN** 17 are acknowledged
- **AND** the result reports 17 succeeded and 3 failed, listing the 3 with the
  reason "already resolved"
- **AND** 17 acknowledgement rows are written

#### Scenario: Forged ids are rejected

- **WHEN** a crafted bulk submission includes an alert id outside the viewer's
  permitted scope
- **THEN** that id is rejected during server-side re-authorization
- **AND** the remaining permitted ids are still processed
- **AND** the rejected id is reported as failed without disclosing whether it
  exists

#### Scenario: Selection bound is enforced

- **WHEN** a submission carries more ids than the configured bulk limit
- **THEN** the action is refused with a message stating the limit
- **AND** no alert is mutated

### Requirement: Notification RBAC Permission Keys

`ServiceRadar.Identity.RBAC.Catalog` SHALL gain a TOP-LEVEL `notifications`
section whose permission keys follow the existing three-part
`<section>.<noun>.<verb>` convention used by the `observability`, `northbound`,
and `settings` sections -- the same shape as `observability.alerts.manage`. The
section SHALL define EXACTLY these NINE keys:

- `notifications.channels.view`
- `notifications.channels.manage`
- `notifications.routes.view`
- `notifications.routes.manage`
- `notifications.providers.manage`
- `notifications.deliveries.view`
- `notifications.test.send`
- `notifications.silences.manage`
- `notifications.stream.subscribe`

Four-part keys MUST NOT be introduced, and these keys MUST NOT be nested under
another section as `observability.notifications.*`.

`notifications.stream.subscribe` is the firehose permission: it is the key a
consumer must hold to join the `:stream` provider's Phoenix Channel topic.

Each key MUST carry a `label`, a `description`, and `default_roles` drawn from
the existing `ServiceRadar.Identity.Constants` role sets. Management-class keys
(`*.manage`, `notifications.providers.manage`) MUST NOT default to viewer roles;
`notifications.providers.manage`, which permits uploading executable-adjacent
provider definitions, MUST default to admin roles only.
`notifications.stream.subscribe` grants a continuous feed of every notification
delivered to the stream and MUST NOT default to viewer roles either.

All keys MUST appear in `RBAC.Catalog.permission_keys/0`, so the Settings
catalog gate can validate the notifications view's permission.

The existing `observability.alerts.manage` remains the sole gate for alert
acknowledgement, snooze, resolve, and suppress. This change MUST NOT introduce a
duplicate notification-section permission for those actions.

#### Scenario: New keys are catalogued

- **WHEN** `RBAC.Catalog.permission_keys/0` is evaluated after the change
- **THEN** it contains all NINE `notifications.*` keys, including
  `notifications.stream.subscribe`
- **AND** every one of them is a three-part `<section>.<noun>.<verb>` key, with
  no four-part key and none nested under `observability`
- **AND** each has a non-empty label and description
- **AND** the Settings catalog test finds the notifications view permission

#### Scenario: Provider upload is admin-only by default

- **WHEN** a user is assigned the default operator profile
- **THEN** the resulting permission set includes `notifications.channels.manage`
  and `notifications.test.send`
- **AND** excludes `notifications.providers.manage`

#### Scenario: Alert acknowledgement is not duplicated

- **WHEN** the notifications section is inspected
- **THEN** it contains no `notifications.alerts.acknowledge`-style key
- **AND** acknowledgement remains gated by `observability.alerts.manage`

### Requirement: Notification LiveView Authorization Discipline

Every notification LiveView MUST authorize inside EVERY `handle_event/3` before
performing any side effect. This applies to the settings tabs, the alert detail
controls, and the alert list bulk actions alike. The check MUST use the scope
stored on the socket by the authenticated session, never a scope, user id, or
permission list read from event parameters.

An unauthorized event MUST produce no state change, no outbound request, and no
database write, and MUST NOT disclose whether the referenced record exists.

No LiveView, component, or helper in this surface may call `String.to_atom/1` or
`String.to_existing_atom/1` on user input; enumerated values (tab names, states,
suppression reasons, conditions, provider types, execution routes, snooze
durations, predicate operators) MUST be mapped through explicit whitelists.

Server-derived fields -- `partition_id`, `created_by_user_id`,
`acknowledged_by_user_id`, `actor_kind` -- MUST be taken from the authenticated
context and MUST be ignored if present in submitted parameters.

Mutating events MUST be safe against double submission: a repeated identical
submit MUST NOT create a duplicate channel, silence, acknowledgement, or test
send.

#### Scenario: Every mutating event authorizes

- **WHEN** the notification LiveView modules are reviewed
- **THEN** every `handle_event/3` clause that mutates state begins with an
  authorization check against the socket scope
- **AND** the corresponding negative-path test asserts refusal for a scope
  lacking the permission

#### Scenario: No atom creation from input

- **WHEN** a crafted event supplies an unexpected tab name, provider type, or
  condition string
- **THEN** it is rejected by the whitelist mapping
- **AND** no new atom is created

#### Scenario: Server-derived fields ignored from params

- **WHEN** a submission includes `partition_id` or `actor_kind`
- **THEN** the supplied values are discarded and the server-derived values used

#### Scenario: Double submit is idempotent

- **WHEN** an operator double-clicks Save on a new silence
- **THEN** exactly one `NotificationSilence` is created

### Requirement: Notification LiveView Lifecycle and Scale Discipline

Notification LiveViews MUST obey the project LiveView Iron Laws.

No database query may run in a disconnected mount. The disconnected render MUST
produce a loading state, with data loaded after `connected?/1` is true.

Every list that can exceed 100 rows -- deliveries, channels, routes, silences,
providers -- MUST use LiveView streams with server-side pagination or a bounded
limit. The Delivery Log in particular MUST NOT load an unbounded result set into
socket assigns.

PubSub subscription MUST occur only when `connected?(socket)` is true. Live
updates pushed to a subscribed socket MUST be filtered by the viewer's
permissions: a viewer without `notifications.deliveries.view` MUST NOT receive
delivery events, and a viewer MUST NOT receive an envelope for a record it may
not read.

Filter and pagination changes MUST flow through `handle_params/3` with
debouncing on free-text inputs, so keystrokes do not issue one query each.

#### Scenario: Disconnected mount is query-free

- **WHEN** the first, disconnected render of `/settings/notifications/deliveries`
  occurs
- **THEN** no database query is issued
- **AND** a loading skeleton is rendered
- **AND** the data query runs on the connected mount

#### Scenario: Large delivery volume is streamed

- **WHEN** a deployment has 500,000 delivery rows and an operator opens the
  Delivery Log
- **THEN** the LiveView renders a bounded page via a stream
- **AND** memory held in socket assigns does not grow with the total row count

#### Scenario: Live updates are permission-filtered

- **WHEN** a new suppressed `NotificationDelivery` row is broadcast to the
  Delivery Log's internal LiveView topic -- which is the settings surface, not
  the `:stream` provider's firehose -- while two operators are viewing it, one
  with and one without `notifications.deliveries.view`
- **THEN** only the permitted operator's socket receives and renders the update

### Requirement: Notification UI Component and Accessibility Conventions

The notification surfaces MUST be built from the project-owned `sr-*` Tailwind
v4 tokens (`sr-canvas`, `sr-surface`, `sr-raised`, `sr-muted`, and the rest
declared in `elixir/web-ng/assets/css/app.css`) and from
`ServiceRadarWebNGWeb.UIComponents` -- `ui_panel`, `ui_button`, `ui_badge`,
`ui_tabs`, `ui_table_class`, `ui_field_class` -- over the slimmed
`CoreComponents`.

daisyUI has been REMOVED from the asset pipeline. These surfaces MUST NOT use
daisyUI class names (`btn`, `card`, `badge`, `tabs`, `tab-active`, `modal`,
`input`, `select`, `alert`, `menu`, `drawer`, `table-zebra`, and siblings) and
MUST NOT reintroduce the daisyUI plugin. Colors MUST come from tokens; hardcoded
hex values are prohibited so light and dark themes stay correct.

Accessibility requirements, all normative:

- Tabs expose the correct roles and `aria-selected`, and are keyboard navigable.
- Every icon-only control carries an accessible name.
- Form controls have associated labels, and inline validation errors are
  programmatically associated with their field.
- State conveyed by color -- channel health, delivery state, silence state --
  MUST also be conveyed by text or an accessible label.
- Destructive or high-impact actions -- disable channel, disable provider,
  cancel silence, resolve alert, bulk acknowledge -- require explicit
  confirmation.
- Opening a dialog moves focus into it and closing returns focus to the invoking
  control.

#### Scenario: No daisyUI classes are introduced

- **WHEN** the notification LiveViews and components are scanned for daisyUI
  class names
- **THEN** none are present
- **AND** every surface, border, and text color resolves through an `sr-*` token

#### Scenario: Health is not color-only

- **WHEN** a channel is unhealthy
- **THEN** its badge carries a text label in addition to the color treatment
- **AND** screen-reader output conveys the health state

#### Scenario: Destructive action is confirmed

- **WHEN** an operator clicks Disable on a channel
- **THEN** a confirmation names the channel and its consequence
- **AND** focus moves into the confirmation and returns to the trigger on close

### Requirement: Firehose Subscription Surface

The `:stream` provider's output SHALL be consumable over an authenticated,
RBAC-scoped subscription so external consumers can drink from the firehose
without a parallel unaudited egress path.

The subscription MUST be a Phoenix Channel topic declared on
`ServiceRadarWebNGWeb.UserSocket`. Joining MUST require an authenticated socket
(the existing Guardian token connect path) AND the RBAC permission
`notifications.stream.subscribe`; a join without it MUST be refused with an
explicit reason and no payload.

Envelopes delivered on the topic MUST be the canonical notification envelope
AFTER routing, suppression, and redaction -- identical in content policy to what
any other channel receives. A subscriber MUST NOT receive an envelope it lacks
permission to see.

A SUPPRESSED dispatch to a `:stream` channel MUST publish NO envelope on the
topic. The withheld dispatch is recorded as a `NotificationDelivery` row with
`state: :suppressed` and its `suppression_reason`, and the DELIVERY LOG -- not
the stream -- is the surface that displays those suppressed rows with their
reason and answers "why was I not paged?". The firehose carries notifications
that were actually delivered to the stream; it is not a suppression audit feed,
and the UI MUST document it that way so a consumer does not treat stream silence
as evidence that nothing was withheld.

The `:stream` provider is EXEMPT from the requirement that a rendered
notification carry signed Acknowledge, Snooze, and Resolve action links.
Embedding a single-use capability token in a broadcast envelope that every
permitted subscriber receives is a credential leak. Firehose envelopes MUST
therefore carry no acknowledgement token and no capability link; a firehose
consumer acknowledges through the authenticated API, not through the envelope.

A reconnecting consumer MUST be able to resume from a durable cursor: the join
accepts a last-seen sequence or cursor and the server replays missed envelopes
from the backing JetStream subject rather than silently losing them. When the
requested cursor is beyond the retained window, the server MUST signal the gap
explicitly instead of returning a silently truncated stream.

Overflow MUST be explicit: when a slow consumer cannot keep up, the server
signals the drop rather than discarding silently.

The UI SHALL document this surface for external consumers, in the Providers or
Delivery Log tab, naming the topic, the authentication method, the required
permission `notifications.stream.subscribe`, the envelope schema, the cursor and
replay semantics, the absence of acknowledgement tokens in envelopes, and the
fact that suppressed dispatches appear only in the Delivery Log.

#### Scenario: Authenticated, permitted join

- **WHEN** a consumer connects the socket with a valid session token and joins
  the notification firehose topic holding the required permission
- **THEN** the join succeeds
- **AND** subsequent notification envelopes are pushed as they are produced

#### Scenario: Join without permission is refused

- **WHEN** an authenticated consumer lacking the required permission attempts to
  join
- **THEN** the join is refused with an explicit reason
- **AND** no envelope is delivered

#### Scenario: Reconnect replays from a cursor

- **WHEN** a consumer disconnects, 240 envelopes are produced, and it rejoins
  supplying its last-seen cursor
- **THEN** the 240 missed envelopes are replayed from the durable subject in
  order
- **AND** the consumer observes no gap

#### Scenario: Cursor beyond retention is signalled

- **WHEN** a consumer rejoins with a cursor older than the retained window
- **THEN** the server responds with an explicit gap signal naming the earliest
  available cursor
- **AND** does not present the truncated replay as complete

#### Scenario: Firehose envelopes are redacted

- **WHEN** an envelope for a channel whose payload contained a credential is
  published to the firehose
- **THEN** the envelope has passed `northbound-action-redaction-v1`
- **AND** carries no secret value, no `secret_refs` resolution, and no
  acknowledgement token

#### Scenario: A suppressed dispatch publishes nothing on the stream

- **WHEN** a dispatch to a `:stream` channel is suppressed by an active silence
- **THEN** NO envelope is published on the firehose topic for that dispatch
- **AND** a `NotificationDelivery` row is written with `state: :suppressed` and
  `suppression_reason: :silence`

#### Scenario: The Delivery Log shows what the stream withheld

- **WHEN** an operator opens the Delivery Log after that suppressed dispatch
- **THEN** the suppressed row is displayed with its `suppression_reason` rather
  than omitted
- **AND** it links to the silence that caused it
- **AND** the operator can answer "why was I not paged?" from the Delivery Log
  without inspecting the stream

#### Scenario: Firehose envelopes carry no action links

- **WHEN** an envelope is published to the firehose for a notification that
  would carry Acknowledge, Snooze, and Resolve links on any other channel
- **THEN** the envelope contains no capability token and no action link
- **AND** the exemption is documented on the subscription surface
