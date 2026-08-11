## ADDED Requirements

### Requirement: Single Provider Transport Contract

The system SHALL define exactly one provider contract, the
`ServiceRadar.Notifications.Transport` behaviour, and every notification
provider SHALL be reachable only through it.

The platform SHALL offer exactly three extensibility tiers - `:native`,
`:declarative`, and `:wasm_plugin` - plus the built-in `:stream` provider type.
`:stream` is a `provider_type` but is **not** an extensibility tier, because an
operator cannot author one: it is shipped, seeded, and maintained by the
platform. All four `provider_type` values SHALL be reachable only through the
single transport behaviour.

The behaviour SHALL declare these callbacks:

- `deliver/2` - accepts a resolved channel context and a rendered payload and
  returns `{:ok, result}` where `result` carries
  `external_correlation_id` and `result_summary`, or
  `{:error, %{error_class: atom(), error_message: String.t(), retryable?: boolean()}}`.
- `validate_config/1` - validates a channel `config` map against the provider
  `config_schema` and returns `:ok` or `{:error, errors}` without performing any
  network egress.
- `capabilities/0` - returns the provider capability list, drawn from
  `[:send, :test, :resolve_update, :inbound_callback, :rich_payload, :attachments, :threading]`.
- `test/2` - performs a test send against real configuration and real resolved
  secrets, per "Provider Test Send".

The decision engine SHALL remain tier-agnostic. `ServiceRadar.Notifications`
routing, escalation, suppression, deduplication, rate limiting, and
acknowledgement code paths MUST NOT branch on `provider_type`,
`implementation_module`, `plugin_package_id`, or the presence of a declarative
`definition`. Tier-specific behaviour SHALL be confined to the transport
dispatch layer that resolves a channel to a `Transport` implementation.

Every transport return value SHALL be normalised into the same
`NotificationDelivery` state vocabulary
(`:pending`, `:dispatching`, `:sent`, `:failed`, `:expired`, `:cancelled`,
`:suppressed`, `:skipped`) regardless of `provider_type`.

#### Scenario: Every provider type satisfies one behaviour

- **WHEN** a notification is dispatched to a channel whose provider is
  `:native`, `:declarative`, `:wasm_plugin`, or `:stream`
- **THEN** dispatch SHALL invoke `ServiceRadar.Notifications.Transport.deliver/2`
  on the resolved implementation
- **AND** the outcome SHALL be recorded on the `NotificationDelivery` row using
  the shared state vocabulary
- **AND** no caller outside the transport dispatch layer SHALL read
  `provider_type`

#### Scenario: Engine code must not branch on provider type

- **WHEN** routing, escalation, suppression, deduplication, or acknowledgement
  logic is evaluated for a delivery
- **THEN** the evaluation result SHALL be identical for two channels that differ
  only in `provider_type`
- **AND** a code change that introduces a `provider_type` branch in those
  modules SHALL be rejected by the tier-agnosticism test

#### Scenario: Transport errors are classified uniformly

- **WHEN** a transport returns `{:error, %{retryable?: true}}`
- **THEN** the delivery SHALL be scheduled for retry under `max_attempts` and
  Oban backoff
- **AND** the same handling SHALL apply whether the error originated from an
  Elixir HTTP client, a declarative request template, an agent command result,
  or a stream publish failure

### Requirement: Notification Provider Registry Resource

The system SHALL provide a `NotificationProvider` Ash resource in the
`ServiceRadar.Notifications` domain, stored in the `platform` schema with a
`uuid_generate_v7()` primary key, representing a *kind* of destination.

The resource SHALL carry at least the following attributes:

- `provider_key` - unique, lowercase, stable identifier such as `slack`,
  `discord`, `webhook`, `email`, `pagerduty`.
- `provider_type` - one of `:native`, `:declarative`, `:wasm_plugin`,
  `:stream`.
- `display_name`, `description`, `icon`.
- `config_schema` - a JSON Schema subset validated by
  `ServiceRadar.Plugins.ConfigSchema`.
- `capabilities` - a subset of
  `[:send, :test, :resolve_update, :inbound_callback, :rich_payload, :attachments, :threading]`
  that SHALL contain at least `:send` and `:test`.
- `supported_routes` - a non-empty subset of `[:control_plane, :edge_agent]`.
- `payload_formats` - a non-empty subset of
  `[:slack_blocks, :discord_embed, :markdown, :plain, :html, :pagerduty_v2, :json]`.
- `definition` - the request-template document; permitted only when
  `provider_type == :declarative`.
- `plugin_package_id` and `action_key` - permitted only when
  `provider_type == :wasm_plugin`. `action_key` SHALL equal a `key` value in the
  `notifications:` block of the referenced package's validated manifest; it is
  not a free-form string and MUST NOT be resolvable to anything the manifest did
  not declare.
- `implementation_module` - permitted only when `provider_type == :native`.
- `source` - one of `:first_party`, `:uploaded`, `:plugin`.
- `managed`, `template_version`, `template_fingerprint` - upgrade
  reconciliation metadata.

The resource SHALL use an `AshStateMachine` with states `:draft`, `:active`,
`:disabled` and transitions `:draft -> :active`, `:active -> :disabled`, and
`:disabled -> :active`. Only providers in state `:active` SHALL be selectable
when creating or enabling a `NotificationChannel`.

The resource SHALL reject a create or update whose tier-specific fields do not
match `provider_type` (for example a `:declarative` provider carrying
`implementation_module`, or a `:native` provider carrying `definition`).

The resource SHALL reject a create or update whose `capabilities` omits `:send`
or `:test`. This applies to every `provider_type`, including `:stream`, and the
same rule SHALL be enforced by the manifest validator: a `notifications:` block
entry whose `capabilities` list does not contain both `send` and `test` SHALL be
rejected at manifest validation, before any provider row can be derived from it.

Disabling a provider SHALL cause every channel bound to it to suppress rather
than fail: dispatch to such a channel SHALL write a `NotificationDelivery` row
with `state: :suppressed` and `suppression_reason: :channel_disabled`.

#### Scenario: Registry entry created and activated

- **WHEN** an administrator creates a `NotificationProvider` with
  `provider_key: "mattermost"`, `provider_type: :declarative`, a valid
  `config_schema`, `supported_routes: [:control_plane]`, and
  `payload_formats: [:json, :markdown]`
- **THEN** the provider SHALL be created in state `:draft`
- **AND** it SHALL NOT be selectable for a channel until it is transitioned to
  `:active`

#### Scenario: Tier field mismatch rejected

- **WHEN** a provider is submitted with `provider_type: :declarative` and a
  populated `implementation_module`
- **THEN** the action SHALL fail validation
- **AND** the error SHALL name the field that is not permitted for that
  `provider_type`

#### Scenario: Provider without send and test capabilities rejected

- **WHEN** a provider is submitted, or a package manifest `notifications:` entry
  is validated, whose `capabilities` list omits `send`, `test`, or both
- **THEN** the create, update, or manifest validation SHALL fail
- **AND** the error SHALL state that `send` and `test` are the minimum capability
  set for every provider type

#### Scenario: Plugin action_key must exist in the manifest

- **WHEN** a `:wasm_plugin` provider declares an `action_key` that is not a `key`
  in the referenced package's validated `notifications:` block
- **THEN** the action SHALL fail validation
- **AND** no provider row SHALL be created or activated

#### Scenario: Disabling a provider suppresses rather than errors

- **GIVEN** an `:active` provider with two enabled channels
- **WHEN** the provider is transitioned to `:disabled`
- **AND** an alert routes to one of those channels
- **THEN** a `NotificationDelivery` row SHALL be written with
  `state: :suppressed` and `suppression_reason: :channel_disabled`
- **AND** no outbound request SHALL be made

#### Scenario: Unknown provider key is not resolvable

- **WHEN** dispatch resolves a channel whose provider row has been deleted or
  whose `provider_key` is absent from the registry
- **THEN** the delivery SHALL be recorded as `:failed` with an
  `error_class` identifying an unresolvable provider
- **AND** the dispatcher MUST NOT attempt to construct a module name from the
  stored string

### Requirement: First-Party Provider Seeding and Upgrade Reconciliation

First-party providers SHALL be seeded and reconciled across releases using the
`managed` / `template_version` / `template_fingerprint` pattern already used by
`ServiceRadar.Observability.PresetRuleResource` and the preset rule seeder, so
that operator edits survive upgrades.

The seeded first-party set SHALL include, at minimum, the four `:native`
providers `slack`, `discord`, `webhook`, and `email`, **and** the built-in
`:stream` provider. The `:stream` provider is a seeded `NotificationProvider`
row like any other - `source: :first_party`, `managed: true`, carrying a
`template_version` and `template_fingerprint` - and is not a special case
constructed at dispatch time. The firehose therefore appears in the provider
list, is selectable when creating a channel, and is disableable through the same
state machine as every other provider.

The seeder SHALL, for each shipped first-party provider definition:

1. Compute a `template_fingerprint` over the shipped definition.
2. Create the provider with `source: :first_party`, `managed: true`, the shipped
   `template_version`, and the computed `template_fingerprint` when no row with
   that `provider_key` exists.
3. Update an existing row in place **only** when `managed == true` **and** the
   stored `template_fingerprint` still matches the fingerprint of the previously
   shipped definition, meaning the operator has not edited it.
4. Leave the row untouched, and record that a newer shipped version is
   available, when `managed == false` or the stored fingerprint indicates local
   modification.

Any operator edit to a managed first-party provider SHALL set `managed` to
`false` (an operator override), and the seeder SHALL NOT clobber it on a
subsequent upgrade.

Seeding SHALL be idempotent: running it repeatedly against an unchanged release
SHALL produce no writes.

#### Scenario: Fresh install seeds first-party providers

- **WHEN** the platform starts against a database with no `NotificationProvider`
  rows
- **THEN** the seeder SHALL create the launch providers `slack`, `discord`,
  `webhook`, and `email` with `source: :first_party`, `managed: true`, and
  `state: :active`
- **AND** it SHALL create the built-in `:stream` provider row with the same
  `source: :first_party` and `managed: true` metadata
- **AND** each row SHALL carry the shipped `template_version` and
  `template_fingerprint`

#### Scenario: Upgrade refreshes an unedited managed provider

- **GIVEN** a seeded provider with `managed: true` whose stored
  `template_fingerprint` matches the previously shipped definition
- **WHEN** a release ships a new `template_version` for that `provider_key`
- **THEN** the seeder SHALL update the row to the new definition, version, and
  fingerprint

#### Scenario: Upgrade preserves an operator-edited provider

- **GIVEN** a seeded provider that an operator has edited, so `managed` is
  `false`
- **WHEN** a release ships a new `template_version` for that `provider_key`
- **THEN** the seeder MUST NOT overwrite the operator's definition
- **AND** the system SHALL surface that a newer shipped version exists

#### Scenario: Re-running the seeder is a no-op

- **WHEN** the seeder runs twice against the same release with no operator
  changes in between
- **THEN** the second run SHALL perform no database writes

### Requirement: Native Provider Tier Uses a Compile-Time Module Allowlist

Providers with `provider_type: :native` SHALL execute an in-tree Elixir module
implementing `ServiceRadar.Notifications.Transport`.

`implementation_module` SHALL be resolved **only** through a compile-time
allowlist map that pairs a `provider_key` with an already-loaded module atom.
The resolver MUST NOT call `String.to_atom/1`, `String.to_existing_atom/1`,
`Module.concat/1`, `Module.concat/2`, or `apply/3` on any operator-supplied or
database-supplied string. A `provider_key` absent from the allowlist SHALL fail
resolution rather than attempt dynamic module construction.

An operator SHALL NOT be able to create, update, or upload a `:native` provider
whose `provider_key` is not already present in the compile-time allowlist;
adding a `:native` provider is an in-tree change plus a release.

The launch allowlist SHALL contain exactly four entries: `slack`, `discord`,
`webhook` (the generic webhook transport), and `email`. The built-in `:stream`
provider and every seeded `:declarative` catalog entry are first-party but are
not `:native`, and SHALL NOT appear in this allowlist.

`:native` transports SHALL remain functional when the plugin host, the platform
agent, and every uploaded declarative definition are unavailable; they are the
delivery floor.

#### Scenario: Allowlisted native provider resolves

- **WHEN** dispatch resolves a channel whose provider has
  `provider_type: :native` and `provider_key: "slack"`
- **THEN** the dispatcher SHALL look up `"slack"` in the compile-time allowlist
- **AND** SHALL invoke `deliver/2` on the returned module

#### Scenario: Non-allowlisted native provider key is rejected at write time

- **WHEN** an administrator submits a provider with `provider_type: :native` and
  `provider_key: "acme_pager"` that is not in the compile-time allowlist
- **THEN** the action SHALL fail validation
- **AND** the error SHALL state that native providers require an in-tree change
  and a release, and that `:declarative` or `:wasm_plugin` is the extension path

#### Scenario: No atom construction from stored strings

- **WHEN** the native resolver receives a `provider_key` string read from the
  database
- **THEN** it MUST NOT call `String.to_atom/1` or otherwise derive a module atom
  from that string
- **AND** an unknown key SHALL return an unresolvable-provider error

#### Scenario: Native tier survives plugin host unavailability

- **GIVEN** the platform-resident agent is unreachable and no declarative
  provider is active
- **WHEN** an alert routes to a channel backed by an allowlisted `:native`
  provider
- **THEN** delivery SHALL still be attempted and recorded

### Requirement: Native Email Transport Uses OutboundMail

The `email` `:native` provider SHALL send every message through
`ServiceRadar.OutboundMail.deliver/1`. It MUST NOT construct its own mailer,
call a Swoosh adapter directly, or reimplement SMTP configuration.

Mailer configuration, credentials, and relay settings SHALL be sourced from the
existing outbound mail settings; the email provider `config_schema` SHALL carry
only per-channel concerns such as recipient addresses, reply-to, and subject
prefix.

The email provider SHALL declare `payload_formats` containing at least
`:plain` and `:html`, and its rendered bodies SHALL be produced by the
restricted templating engine, never by EEx and never through `raw/1`.

Email delivery failures SHALL be classified as retryable or terminal so that
transport retry, and not human escalation, handles transient relay errors.

#### Scenario: Email delivery goes through OutboundMail

- **WHEN** a notification is delivered to a channel backed by the `email`
  provider
- **THEN** the transport SHALL build the message and call
  `ServiceRadar.OutboundMail.deliver/1`
- **AND** MUST NOT invoke a mail adapter directly

#### Scenario: Relay failure is retried, not escalated

- **WHEN** `ServiceRadar.OutboundMail.deliver/1` returns a transient relay error
- **THEN** the delivery SHALL be marked retryable and rescheduled under
  `max_attempts`
- **AND** the alert escalation clock SHALL NOT be advanced by the transport
  failure

### Requirement: Email Transport Prerequisites Are Explicit and Fail Loudly

The `email` `:native` provider SHALL NOT be treated as functional until its two
prerequisites are satisfied, and the system SHALL fail configuration validation
with an actionable diagnostic when either is missing.

SMTP delivery from `serviceradar_core` does not work today:
`elixir/serviceradar_core/mix.exs` declares `swoosh` but **not** `gen_smtp`, and
no deployment template supplies mailer adapter or relay configuration. Swoosh
falls back to a test or local adapter in that situation, which accepts every
message and delivers none. A notification platform that silently swallows pages
is worse than one that refuses to start, so the two prerequisites are:

1. **Dependency.** `gen_smtp` SHALL be added to
   `elixir/serviceradar_core/mix.exs` so that the SMTP adapter is compiled into
   the release. It SHALL be a runtime dependency, present in the production
   release and not only in `:dev` or `:test`.
2. **Deployment configuration.** The mailer adapter, relay host, port,
   authentication mode, TLS settings, and default sender SHALL be supplied by
   deployment configuration - Helm values or environment for the Kubernetes
   path, and the Docker Compose environment for the compose path - and read at
   runtime, not baked at compile time. That deployment configuration is the
   source of the outbound mail settings that
   `ServiceRadar.OutboundMail.deliver/1` consumes; the email transport still
   reads them only through `OutboundMail` and never constructs its own mailer.
   Relay credentials SHALL be secret references resolved through
   `ServiceRadar.Credentials.SecretBroker`, never literals in a values file.

Validation SHALL run at two points and SHALL name the missing prerequisite:

- **At channel save time.** Creating or enabling a channel bound to the `email`
  provider SHALL fail validation when no mailer adapter is configured, and the
  error SHALL state which configuration key is absent and where it is supplied.
- **At startup or provider activation.** When the `email` provider is `:active`
  but the resolved mailer configuration is absent or resolves to a non-delivering
  adapter (for example `Swoosh.Adapters.Test` or `Swoosh.Adapters.Local`) outside
  `:dev` and `:test`, the system SHALL surface an operator-visible configuration
  error and SHALL mark the provider unhealthy.

The transport MUST NOT silently resolve to a test or local adapter in a
production environment, MUST NOT report `:sent` for a message that was only
captured by such an adapter, and MUST NOT degrade to logging the message body.

A test send (see "Provider Test Send") against an email channel SHALL surface the
same diagnostic, so that an operator discovers a missing relay from the
configuration UI rather than from an unpaged incident.

#### Scenario: Missing gen_smtp is a build-time contract failure

- **WHEN** the release is built without `gen_smtp` in
  `elixir/serviceradar_core/mix.exs`
- **THEN** the email transport prerequisite check SHALL fail
- **AND** the failure SHALL name the missing dependency rather than surfacing as
  an adapter error at first delivery

#### Scenario: Unconfigured mailer blocks channel creation with an actionable error

- **GIVEN** a deployment that supplies no mailer adapter or relay configuration
- **WHEN** an operator creates a channel bound to the `email` provider
- **THEN** the action SHALL fail validation
- **AND** the error SHALL name the absent configuration and where it is supplied

#### Scenario: Production never silently uses a test adapter

- **GIVEN** a production deployment whose resolved Swoosh adapter is a test or
  local adapter
- **WHEN** the `email` provider is activated
- **THEN** the system SHALL raise an operator-visible configuration error and
  mark the provider unhealthy
- **AND** no delivery SHALL be recorded `:sent` on the strength of that adapter

#### Scenario: Test send reports the missing prerequisite

- **WHEN** an operator triggers a test send on an email channel in a deployment
  with no relay configured
- **THEN** the test result SHALL report failure
- **AND** the reported reason SHALL identify the missing mailer configuration,
  not a generic transport error

### Requirement: Declarative Provider Request Template Document

Providers with `provider_type: :declarative` SHALL be defined entirely by a
request-template document stored in the `definition` attribute. The document
SHALL be validated against a fixed schema containing:

- `schema_version` - required; the system SHALL reject unknown versions.
- `key` - required; matches the provider `provider_key`.
- `display_name` - required.
- `config_schema` - required; a JSON Schema subset validated by
  `ServiceRadar.Plugins.ConfigSchema`, describing the per-channel configuration
  fields and which of them are secret references.
- `request` - required object with:
  - `method` - one of `POST`, `PUT`, `PATCH`.
  - `url` - a template string.
  - `headers` - a map of header name to template string.
  - `body_format` - one of `json`, `form`, `text`.
  - `body` - a template document or template string rendered per
    `body_format`.
- `success` - required object with `status`, a list of HTTP status codes or
  inclusive ranges that mark the attempt successful.
- `failure` - required object with `retryable_status` (status codes or ranges
  that mark the attempt retryable) and `retry_after_header` (the response header
  consulted for a retry delay).

Every template string in `url`, `headers`, and `body` SHALL be rendered by the
restricted templating engine only.

Any HTTP status not matched by `success.status` and not matched by
`failure.retryable_status` SHALL be treated as a terminal failure.

Validation SHALL reject a document that declares a method other than the
permitted set, an unparsable template, a variable path outside the whitelist, or
a filter outside the fixed filter set.

#### Scenario: Valid declarative document accepted

- **WHEN** a document with `schema_version`, `key`, `display_name`,
  `config_schema`, a `POST` `request`, `success.status: [200, 204]`, and
  `failure.retryable_status: [429, "500-599"]` is validated
- **THEN** validation SHALL succeed
- **AND** the provider SHALL be creatable in state `:draft`

#### Scenario: Unknown schema version rejected

- **WHEN** a document declares a `schema_version` the platform does not
  recognise
- **THEN** validation SHALL fail with an explicit unsupported-version error
- **AND** no provider row SHALL be created

#### Scenario: Response status classification drives retry

- **GIVEN** a declarative provider with `success.status: [200]` and
  `failure.retryable_status: [429, "500-599"]`
- **WHEN** the destination responds `429` with a `Retry-After` header named in
  `failure.retry_after_header`
- **THEN** the delivery SHALL be marked retryable
- **AND** the next attempt SHALL respect the advertised delay
- **WHEN** the destination instead responds `403`
- **THEN** the delivery SHALL be marked `:failed` terminally

#### Scenario: Template outside the restricted language rejected

- **WHEN** a document body contains a filter or variable path outside the
  permitted sets
- **THEN** validation SHALL fail and name the offending expression

### Requirement: Declarative Providers Are Added Without Code or Release

An operator with the notification administration permission SHALL be able to
upload, validate, version, activate, and disable a declarative provider entirely
from the web UI, with **no ServiceRadar code change and no release**.

The system SHALL:

- Accept an uploaded declarative document, validate it, and report every
  validation error before persisting.
- Store the document with `source: :uploaded` and `managed: false`.
- Version the definition so that a superseded version remains readable and a
  channel records which provider version rendered a given delivery.
- Allow transitioning the provider between `:draft`, `:active`, and `:disabled`
  without restarting any service or reloading any application configuration.
- Never require the uploaded `provider_key` to exist in any compile-time
  allowlist.

An uploaded declarative provider SHALL NOT be able to grant itself capabilities,
routes, or payload formats it does not declare, and SHALL NOT be able to declare
`:edge_agent` in `supported_routes` unless a corresponding plugin-backed
execution path exists for it.

#### Scenario: Operator adds a new destination with no release

- **GIVEN** an operator holding the notification administration permission
- **WHEN** they upload a valid declarative document for a destination
  ServiceRadar has never shipped support for
- **AND** activate the resulting provider
- **THEN** a channel SHALL be creatable against it immediately
- **AND** no deployment, restart, or release SHALL be required

#### Scenario: Invalid upload is rejected with actionable errors

- **WHEN** an uploaded document fails validation
- **THEN** the UI SHALL list every validation error with the offending field
  path
- **AND** no provider row SHALL be created

#### Scenario: Superseded version remains auditable

- **GIVEN** an active declarative provider with deliveries recorded against
  version 1 of its definition
- **WHEN** the operator uploads version 2
- **THEN** existing delivery rows SHALL still identify version 1 as the
  definition that rendered them

#### Scenario: Disabling an uploaded provider takes effect without restart

- **WHEN** an operator disables an uploaded declarative provider
- **THEN** subsequent dispatches to its channels SHALL be suppressed with
  `suppression_reason: :channel_disabled`
- **AND** no service restart SHALL be required for the change to take effect

### Requirement: First-Party Declarative Catalog Ships and Is Operator-Disablable

The platform SHALL ship a seeded catalog of first-party `:declarative` providers,
and that catalog SHALL be the executable proof that the declarative tier needs no
ServiceRadar code: every catalog entry SHALL be expressed solely as a
request-template document, with no entry in the `:native` compile-time allowlist
and no `implementation_module`.

The catalog SHALL be seeded through the same
`managed` / `template_version` / `template_fingerprint` reconciliation described
in "First-Party Provider Seeding and Upgrade Reconciliation", with
`source: :first_party` and `managed: true`, so that operator edits to a catalog
entry are preserved across upgrades exactly as for any other managed provider.

Destinations expressible as "POST this body to this URL with these headers" are
the catalog's target - Mattermost, Rocket.Chat, Telegram, ntfy, Gotify, Google
Chat, Microsoft Teams, Opsgenie, and PagerDuty Events API v2 are **examples**,
not a closed list. The set shipped in any given release is a product decision;
this requirement constrains the mechanism, not the membership.

Every catalog entry SHALL be individually operator-disablable:

- An operator holding the notification administration permission SHALL be able to
  transition any catalog entry to `:disabled` without deleting it and without a
  restart, release, or configuration reload.
- A disabled catalog entry SHALL NOT be selectable when creating or enabling a
  channel, and dispatch to an existing channel bound to it SHALL be suppressed
  with `suppression_reason: :channel_disabled` rather than failing.
- The seeder MUST NOT re-enable an entry an operator has disabled. Disabled state
  SHALL survive upgrades, including upgrades that ship a new `template_version`
  for that entry.
- Disabling a catalog entry MUST NOT affect any other entry, nor any `:native`,
  `:wasm_plugin`, or `:stream` provider.

An operator SHALL also be able to disable the catalog as a whole, so that a
deployment that wants only its own uploaded declarative providers can suppress
the shipped set without editing seed data.

Catalog entries SHALL be subject to every constraint that applies to uploaded
declarative providers: the same document schema, the same restricted templating
engine, the same outbound URL policy at request time, and the same capability
negotiation. A first-party origin SHALL NOT grant an entry a relaxed validation
path.

#### Scenario: Catalog is seeded with no native allowlist entry

- **WHEN** the platform starts against a database with no `NotificationProvider`
  rows
- **THEN** the first-party declarative catalog SHALL be seeded with
  `provider_type: :declarative`, `source: :first_party`, and `managed: true`
- **AND** no catalog entry SHALL appear in the `:native` compile-time allowlist
- **AND** no catalog entry SHALL carry an `implementation_module`

#### Scenario: Catalog entry works without a release

- **GIVEN** a seeded catalog entry in state `:active`
- **WHEN** an operator creates and configures a channel against it
- **THEN** delivery SHALL succeed through the declarative HTTP engine
- **AND** no ServiceRadar code change or release SHALL have been required to
  support that destination

#### Scenario: Operator disables one catalog entry

- **GIVEN** a seeded catalog with several `:active` entries
- **WHEN** an operator disables one of them
- **THEN** that entry SHALL NOT be selectable for a new channel
- **AND** dispatch to an existing channel bound to it SHALL be recorded
  `:suppressed` with `suppression_reason: :channel_disabled`
- **AND** every other catalog entry SHALL remain unaffected

#### Scenario: Upgrade does not resurrect a disabled catalog entry

- **GIVEN** a catalog entry an operator has disabled
- **WHEN** a release ships a new `template_version` for that entry
- **THEN** the entry SHALL remain `:disabled`
- **AND** the seeder MUST NOT transition it back to `:active`

#### Scenario: Catalog entries are validated like uploads

- **WHEN** a catalog entry's request-template document is loaded
- **THEN** it SHALL be validated against the same declarative document schema and
  the same restricted templating rules as an operator upload
- **AND** its rendered URLs SHALL pass
  `Palisade.OutboundURLPolicy.validate_https_public_url/2` at request time

### Requirement: Declarative Egress Passes the Outbound URL Policy

Every URL rendered by a declarative provider on the `:control_plane` route SHALL
be validated by `Palisade.OutboundURLPolicy.validate_https_public_url/2`
**after** template substitution and immediately before the request is issued.

Validation SHALL be performed on the final, post-substitution URL. Validating
only the template, or only at provider-upload time, SHALL NOT satisfy this
requirement, because channel configuration and secret resolution can change the
effective host.

A URL that fails the policy SHALL cause the delivery to be recorded as
`:failed` with an `error_class` identifying an outbound policy denial, and the
request MUST NOT be issued. The denied URL SHALL pass `ActionRedaction` before
being written to the delivery row or any log line.

Redirects SHALL NOT be followed to a location that would itself fail the policy.

#### Scenario: Public HTTPS destination allowed

- **WHEN** a declarative provider renders `https://hooks.example.com/services/abc`
- **THEN** `Palisade.OutboundURLPolicy.validate_https_public_url/2` SHALL be
  called with the rendered URL
- **AND** the request SHALL proceed on success

#### Scenario: Private-network destination denied

- **WHEN** a channel's configuration causes the rendered URL to resolve to a
  private or loopback address, or uses a non-HTTPS scheme
- **THEN** the policy SHALL deny it
- **AND** the delivery SHALL be recorded `:failed` with an outbound-policy
  `error_class`
- **AND** no request SHALL be sent

#### Scenario: Substitution result is what gets validated

- **GIVEN** a template `url` of `https://{{ channel.host }}/hook`
- **WHEN** `channel.host` resolves to a denied host
- **THEN** validation SHALL fail on the rendered URL
- **AND** the fact that the template literal looked public SHALL NOT bypass the
  check

### Requirement: Wasm Plugin Provider Tier Executes on the Existing Host

Providers with `provider_type: :wasm_plugin` SHALL execute through the existing
single wazero host inside `serviceradar-agent`, dispatched with the same
`plugin.run_action` command type used by every other plugin action, via
`ServiceRadar.Edge.AgentCommandBus.dispatch/4`.

Route selection SHALL be:

- `execution_route: :control_plane` - dispatch to the **platform-resident**
  `serviceradar-agent` that already ships with the deployment.
- `execution_route: :edge_agent` - dispatch to the site agent named by the
  channel's `agent_uid`, with `partition_id` force-bound server-side and never
  taken from operator input.

The provider's `plugin_package_id` and `action_key` SHALL identify the package
and the action invoked; the payload SHALL be passed as the action parameters.

A plugin-backed channel SHALL NOT be dispatched unless the target agent's
`effective_capabilities` include `notify:v1`. The delivery SHALL be recorded
`:failed` with a capability `error_class` when it does not.

The agent command result SHALL be treated as a **wake-up signal only**. The
`NotificationDelivery` row SHALL remain the system of record, and a bounded
periodic reconciler SHALL recover deliveries whose command result never
arrived.

When dispatch returns `{:error, {:agent_offline, agent_id}}`, the delivery SHALL
fail over to `fallback_channel_id` unless the channel is marked `fail_closed`,
in which case it SHALL be recorded `:failed` with an agent-offline
`error_class`.

A plugin authored for the edge SHALL run unchanged on the platform agent;
relocating a channel between routes SHALL require only a data edit plus a
`PluginAssignment`, never a repackage.

#### Scenario: Control-plane plugin channel runs on the platform agent

- **GIVEN** a channel with `provider_type: :wasm_plugin` and
  `execution_route: :control_plane`
- **WHEN** a notification is dispatched
- **THEN** the system SHALL issue `plugin.run_action` through
  `AgentCommandBus.dispatch/4` to the platform-resident agent
- **AND** SHALL record the `command_id` on the `NotificationDelivery` row

#### Scenario: Edge plugin channel runs on the named site agent

- **GIVEN** a channel with `execution_route: :edge_agent` and an `agent_uid`
- **WHEN** a notification is dispatched
- **THEN** the same `plugin.run_action` command SHALL be dispatched to that
  agent
- **AND** the `partition_id` recorded SHALL be the server-bound value, not any
  operator-supplied value

#### Scenario: Missing notify capability blocks dispatch

- **WHEN** the target agent's `effective_capabilities` do not include
  `notify:v1`
- **THEN** the delivery SHALL be recorded `:failed` with a capability
  `error_class`
- **AND** no command SHALL be dispatched

#### Scenario: Offline agent fails over

- **GIVEN** a plugin-backed edge channel with `fallback_channel_id` set and
  `fail_closed` false
- **WHEN** dispatch returns `{:error, {:agent_offline, agent_id}}`
- **THEN** the delivery SHALL record the offline outcome
- **AND** a single failover hop SHALL be attempted against the fallback channel

#### Scenario: Delivery row survives a lost command result

- **GIVEN** a dispatched plugin delivery whose command result is never received
- **WHEN** the periodic reconciler runs
- **THEN** it SHALL resolve the delivery from the durable row to `:sent`,
  `:failed`, or `:expired`
- **AND** the absence of the command result SHALL NOT leave the delivery
  permanently in `:dispatching`

### Requirement: No Second Wasm Host Runtime

The notification platform MUST NOT introduce a second Wasm host runtime.
Specifically, it MUST NOT add a Rustler or wasmtime NIF in
`serviceradar_core`, a Go sidecar Wasm host, or any other in-core execution of
plugin guests.

All plugin guest execution SHALL occur in the existing `go/pkg/agent` wazero
host, which owns the guest ABI, the ptr/len memory convention, the plugin error
return codes, per-call capability gating, domain and port allowlists, redirect
suppression on credential-bearing requests, TLS trust, and credential
injection.

Central execution SHALL be achieved by dispatching to the platform-resident
agent, not by reimplementing the host.

#### Scenario: Central plugin execution reuses the agent host

- **WHEN** a `:control_plane` plugin-backed notification requires guest
  execution
- **THEN** execution SHALL occur in the `serviceradar-agent` wazero host
- **AND** `serviceradar_core` MUST NOT instantiate a Wasm runtime

#### Scenario: A proposed in-core host is out of contract

- **WHEN** an implementation adds a Wasm runtime dependency to
  `serviceradar_core` or a second host implementation of the guest ABI
- **THEN** it SHALL be rejected as violating the single-host invariant

### Requirement: Built-In Stream Provider Type

Providers with `provider_type: :stream` SHALL publish the canonical notification
envelope rather than perform outbound HTTP. `:stream` is a built-in
`provider_type`, not an extensibility tier: operators configure and disable it,
but they cannot author a new one.

A stream provider SHALL:

- Implement the same `ServiceRadar.Notifications.Transport` behaviour, so that
  the firehose traverses the same routing, suppression, redaction, and audit
  path as any other channel.
- Publish to a durable JetStream subject in the notification subject namespace,
  so that a reconnecting consumer replays from a durable cursor instead of
  silently losing events.
- Fan the envelope out to an RBAC-scoped Phoenix Channel topic; a subscriber
  SHALL receive only envelopes it is authorised to see.
- Declare `supported_routes: [:control_plane]` and `payload_formats: [:json]`.
- Apply `ActionRedaction` (policy `northbound-action-redaction-v1`) to the
  envelope before publication.

A stream delivery SHALL produce a `NotificationDelivery` row exactly as any
other provider type does, including `:suppressed` rows when suppression applies.
A suppressed dispatch to a `:stream` channel SHALL publish **no** envelope on the
stream and SHALL write a `NotificationDelivery` row with `state: :suppressed` and
its `suppression_reason`. Suppressed dispatches are visible through the delivery
log, not through the firehose.

The `:stream` provider SHALL be **exempt** from the requirement that a rendered
notification carry acknowledge, snooze, and resolve action links. Those links
carry a single-use capability token scoped to one delivery; embedding one in a
broadcast envelope that every authorised subscriber receives is a credential
leak. A stream envelope SHALL instead carry the `alert_id` and `delivery_id` so a
subscriber can act through the authenticated API, and the token minting path
SHALL skip `:stream` deliveries entirely rather than minting a token that is
then withheld.

Subscribing to notifications MUST NOT be possible through any path that bypasses
this provider; there SHALL be no unaudited side-door egress of notification
events.

The notification subject namespace SHALL be added to the per-CN publish and
subscribe allowlists in the NATS Helm template; a namespace absent from those
allowlists is denied at the broker.

#### Scenario: Stream channel records a delivery like any other

- **WHEN** an alert routes to a `:stream` channel
- **THEN** a `NotificationDelivery` row SHALL be written
- **AND** suppression SHALL be evaluated for it exactly as for a Slack channel

#### Scenario: Suppressed stream dispatch publishes nothing

- **GIVEN** a `:stream` channel and a dispatch that suppression withholds
- **WHEN** the dispatch decision is recorded
- **THEN** no envelope SHALL be published to the JetStream subject or the Phoenix
  Channel topic
- **AND** a `NotificationDelivery` row SHALL be written with `state: :suppressed`
  and its `suppression_reason`
- **AND** that row SHALL be visible in the delivery log

#### Scenario: Stream envelopes carry no capability token

- **WHEN** the stream transport renders an envelope for an alert
- **THEN** the envelope MUST NOT contain an acknowledge, snooze, or resolve
  action link or any single-use capability token
- **AND** it SHALL carry `alert_id` and `delivery_id` so a subscriber can act
  through the authenticated API instead

#### Scenario: Redacted envelope published durably

- **WHEN** the stream transport publishes an envelope
- **THEN** the envelope SHALL have passed `ActionRedaction` first
- **AND** it SHALL be published to a durable JetStream subject before being
  broadcast to the Phoenix Channel topic

#### Scenario: Reconnecting consumer replays

- **GIVEN** a subscriber that disconnects and reconnects
- **WHEN** it resumes from its durable cursor
- **THEN** it SHALL receive envelopes published while it was disconnected

#### Scenario: Unauthorised subscriber sees nothing

- **WHEN** a subscriber lacking the required RBAC scope joins the firehose topic
- **THEN** the join SHALL be denied
- **AND** no envelope SHALL be delivered to it

#### Scenario: Subject namespace must be allowlisted at the broker

- **WHEN** the notification subject namespace is not present in the per-CN
  publish and subscribe allowlists
- **THEN** publication SHALL be denied at the broker
- **AND** the delivery SHALL be recorded `:failed` rather than silently dropped

### Requirement: Restricted Templating Language

Notification templates SHALL be rendered by a restricted substitution engine
that is not a programming language. This applies to notification bodies,
subject lines, and every declarative request template field (`url`, `headers`,
`body`).

The engine SHALL:

- Resolve **only** whitelisted variable paths, drawn from a published variable
  catalog covering the alert, its snapshot, the device or subject, the rule, the
  route, the channel, the delivery, and the acknowledgement action links. An
  unknown path SHALL be a validation error at template-save time, not a silent
  empty string at render time.
- Support **only** the fixed filter set `upper`, `lower`, `truncate`, `json`,
  `url_encode`, `iso8601`, `default`.
- Support **no** conditionals, loops, comparisons, arithmetic, function
  definitions, or module calls. `default` is the only permitted fallback
  construct.
- Never use EEx, `Code.eval_string/1`, `EEx.eval_string/2`, or any dynamic code
  evaluation.
- Never emit content through `raw/1`; rendered values SHALL be escaped for their
  destination format.

Provider definitions and provider-supplied UI descriptors MUST NOT contain
markup or code keys. Consistent with the existing manifest validator, the keys
`html`, `raw_html`, `javascript`, `js`, `component`, `component_ref`,
`live_view`, `react`, and `ui_code` SHALL be hard-rejected wherever a provider
describes itself. Providers describe their configuration and display
declaratively via JSON Schema and a display contract; they never ship markup.

Any provider requiring expressiveness beyond this engine - request signing,
OAuth exchange, conditional payload shape, non-HTTP transport - MUST be
implemented as a `:wasm_plugin`, not by extending the templating language.

#### Scenario: Whitelisted path and filter render

- **WHEN** a body template contains `{{ alert.title | truncate: 80 }}` and
  `{{ alert.first_seen_at | iso8601 }}`
- **THEN** rendering SHALL succeed
- **AND** the output SHALL be escaped for the destination `body_format`

#### Scenario: Unknown variable path rejected at save time

- **WHEN** a template references a variable path outside the published catalog
- **THEN** saving the template SHALL fail validation naming the path
- **AND** the template SHALL NOT be persisted

#### Scenario: Unknown filter rejected

- **WHEN** a template uses a filter outside
  `upper`, `lower`, `truncate`, `json`, `url_encode`, `iso8601`, `default`
- **THEN** validation SHALL fail naming the filter

#### Scenario: Conditional syntax rejected

- **WHEN** a template contains an `if`, `unless`, `for`, or comparison construct
- **THEN** validation SHALL fail
- **AND** the error SHALL state that expressive logic requires a Wasm plugin

#### Scenario: Markup and code keys rejected in provider descriptors

- **WHEN** a provider definition or display contract contains any of `html`,
  `raw_html`, `javascript`, `js`, `component`, `component_ref`, `live_view`,
  `react`, or `ui_code`
- **THEN** validation SHALL reject the definition

#### Scenario: No dynamic evaluation

- **WHEN** any template is rendered
- **THEN** rendering MUST NOT invoke EEx or any code-evaluation function
- **AND** MUST NOT pass rendered content through `raw/1`

### Requirement: NotificationTemplate Resource and Managed Defaults

The system SHALL provide a `NotificationTemplate` Ash resource in the
`ServiceRadar.Notifications` domain, stored in the `platform` schema with a
`uuid_generate_v7()` primary key, that owns the subject and body templates used
to render a notification.

The resource SHALL carry at least:

- `alert_class` - the class of alert the template renders (for example the rule
  category or a catch-all default), forming half of the selection key.
- `payload_format` - one of
  `[:slack_blocks, :discord_embed, :markdown, :plain, :html, :pagerduty_v2, :json]`,
  forming the other half of the selection key.
- `provider_key` - optional; when present the template applies only to that
  provider, and it SHALL take precedence over a template that matches on
  `payload_format` alone.
- `subject_template` and `body_template` - rendered exclusively by the restricted
  templating engine defined in "Restricted Templating Language", using the same
  whitelisted variable catalog and the same fixed filter set `upper`, `lower`,
  `truncate`, `json`, `url_encode`, `iso8601`, `default`. No second engine, no
  second filter set, and no EEx.
- `managed`, `template_version`, `template_fingerprint` - upgrade reconciliation
  metadata, identical in meaning to the fields on `NotificationProvider`.
- `enabled`.

Selection SHALL be deterministic on the pair (alert class x payload format).
Rendering a notification SHALL resolve exactly one template by, in order:
an enabled template matching `{provider_key, alert_class, payload_format}`; then
`{alert_class, payload_format}`; then the shipped default for that
`payload_format`. Two enabled templates SHALL NOT be able to match the same
selection key with the same specificity; the resource SHALL reject the second
one at write time rather than resolving the ambiguity at dispatch.

First-party defaults SHALL ship for every `payload_format` the launch providers
declare, seeded with `managed: true`, a `template_version`, and a
`template_fingerprint` computed over the shipped content, using the same seeder
contract as first-party providers. Rendering SHALL never fail for want of a
template: when no operator template matches, the shipped default renders.

Operator overrides SHALL be preserved across upgrades. An operator edit to a
managed template SHALL set `managed` to `false`, and the seeder SHALL update a
template in place **only** when `managed == true` **and** the stored
`template_fingerprint` still matches the previously shipped content. When a
newer shipped version exists for an overridden template, the system SHALL record
and surface that fact rather than overwriting the operator's content, and SHALL
make the shipped version readable so an operator can diff and adopt it
deliberately.

The negotiated `payload_format` actually rendered SHALL be recorded on the
`NotificationDelivery` row, so a delivery can be traced to the template and
format that produced it.

#### Scenario: Template resolved by alert class and payload format

- **GIVEN** an enabled template for a given `alert_class` and
  `payload_format: :markdown`
- **WHEN** a notification of that alert class is rendered for a channel whose
  negotiated format is `:markdown`
- **THEN** that template SHALL be selected
- **AND** the delivery row SHALL record `:markdown` as the format rendered

#### Scenario: Provider-specific template wins over a format-only template

- **GIVEN** both a `{provider_key, alert_class, payload_format}` template and an
  `{alert_class, payload_format}` template, both enabled
- **WHEN** a notification is rendered for a channel bound to that `provider_key`
- **THEN** the provider-specific template SHALL be selected

#### Scenario: Ambiguous templates rejected at write time

- **WHEN** an operator saves a second enabled template whose selection key and
  specificity duplicate an existing enabled template
- **THEN** the action SHALL fail validation naming the conflicting template
- **AND** dispatch SHALL never have to break the tie

#### Scenario: Missing template falls back to the shipped default

- **WHEN** no operator template matches the resolved alert class and payload
  format
- **THEN** the shipped first-party default for that `payload_format` SHALL render
- **AND** the delivery MUST NOT fail for want of a template

#### Scenario: Upgrade preserves an operator-edited template

- **GIVEN** a first-party template an operator has edited, so `managed` is
  `false`
- **WHEN** a release ships a new `template_version` for that template
- **THEN** the seeder MUST NOT overwrite the operator's content
- **AND** the system SHALL surface that a newer shipped version exists and make
  it readable for comparison

#### Scenario: Upgrade refreshes an unedited managed template

- **GIVEN** a first-party template with `managed: true` whose stored
  `template_fingerprint` matches the previously shipped content
- **WHEN** a release ships new content for it
- **THEN** the seeder SHALL update the content, version, and fingerprint in place

#### Scenario: Templates use only the restricted engine

- **WHEN** a `subject_template` or `body_template` is saved
- **THEN** it SHALL be validated against the whitelisted variable catalog and the
  filter set `upper`, `lower`, `truncate`, `json`, `url_encode`, `iso8601`,
  `default`
- **AND** an EEx construct, a conditional, or an unknown filter SHALL fail
  validation at save time

### Requirement: Provider Secret Handling

Secrets used by notification providers SHALL be referenced, never embedded.

Channel configuration SHALL carry secret references in `secret_refs` using
`ServiceRadar.Plugins.SecretRefs`, and every resolution SHALL go through
`ServiceRadar.Credentials.SecretBroker`. Notification code MUST NOT call
`Vault.decrypt!` or any equivalent decryption primitive directly.

For `:wasm_plugin` providers, secret material MUST NOT enter Wasm guest memory
and MUST NOT appear in `params_json`. Secrets SHALL reach the destination by
one of exactly two mechanisms:

1. `CredentialBrokerGrant` host-side injection, where the agent host injects the
   credential into the outbound request using one of the supported injection
   modes - `http_header`, `bearer_token`, `basic_auth`, `query`,
   `form_urlencoded`, or `oauth2_password_bearer` - which are the canonical mode
   names owned by `go/pkg/agent/plugin_runtime_actions.go`; the short forms
   `header`, `bearer`, `basic`, and `form` are NOT valid mode names, or
2. the trusted-host-only proto field `host_params_json`, which the host reads
   and the guest never receives.

For `:native` and `:declarative` providers on the `:control_plane` route,
secrets SHALL be resolved in Elixir by `SecretBroker` immediately before the
request is issued, held only for the duration of the attempt, and never
persisted into the delivery row.

Resolved secret values MUST NOT be written to `rendered_payload_digest`
inputs in cleartext, to `result_summary`, to `error_message`, or to any log
line. Every payload and log line SHALL pass `ActionRedaction` (policy
`northbound-action-redaction-v1`) before persistence or display.

A provider `config_schema` SHALL mark secret-bearing fields explicitly so the
configuration UI renders them as secret references rather than plain values.

#### Scenario: Guest never receives the secret

- **WHEN** a `:wasm_plugin` notification action is dispatched
- **THEN** `params_json` SHALL contain no secret material
- **AND** the credential SHALL be supplied by `CredentialBrokerGrant` host-side
  injection or `host_params_json`
- **AND** the guest SHALL be unable to read the credential from its own memory

#### Scenario: Resolution goes through the broker

- **WHEN** a channel's `secret_refs` are resolved for any `provider_type`
- **THEN** resolution SHALL be performed by
  `ServiceRadar.Credentials.SecretBroker`
- **AND** the code path MUST NOT call `Vault.decrypt!` directly

#### Scenario: Secrets are redacted from persisted records

- **WHEN** a delivery attempt succeeds or fails
- **THEN** `result_summary`, `error_message`, and any persisted payload
  representation SHALL have passed `ActionRedaction`
- **AND** SHALL contain no resolved secret value

#### Scenario: Secret fields are declared in the config schema

- **WHEN** a provider declares a configuration field that holds a credential
- **THEN** the `config_schema` SHALL mark it as a secret reference
- **AND** the configuration UI SHALL render it as a secret reference field

### Requirement: Slack and Discord Incoming Webhook URL Constraint

The system SHALL resolve the incoming-webhook URL constraint as specified below,
and MUST NOT work around it by adding a new credential injection mode. Slack and
Discord incoming-webhook URLs carry the secret **in the URL path**, and none of
the supported injection modes - `http_header`, `bearer_token`, `basic_auth`,
`query`, `form_urlencoded`, `oauth2_password_bearer` - rewrites a URL path
segment.

- On the `:control_plane` route, an incoming-webhook URL SHALL be treated as
  channel configuration held as a secret reference and resolved in Elixir by
  `Credentials.SecretBroker` immediately before the request is issued. The
  rendered URL SHALL still pass
  `Palisade.OutboundURLPolicy.validate_https_public_url/2`, and SHALL be
  redacted in every persisted record and log line.
- On the `:edge_agent` route, a Slack or Discord channel SHALL either
  (a) use the bot-token API (for example Slack `chat.postMessage`) with the
  credential injected as `bearer_token`, or
  (b) carry the webhook URL through `host_params_json` so the guest never sees
  it.
- Adding a URL-path credential injection mode is explicitly **out of scope**;
  an implementation MUST NOT introduce one.

Provider metadata SHALL make this reachable to operators: an incoming-webhook
style provider SHALL declare `supported_routes` that reflect which of the above
paths it actually supports, so the UI cannot offer an unsupported combination.

#### Scenario: Control-plane webhook URL resolved in Elixir

- **GIVEN** a Slack channel with `execution_route: :control_plane` configured
  with an incoming-webhook URL held as a secret reference
- **WHEN** a notification is delivered
- **THEN** the URL SHALL be resolved by `Credentials.SecretBroker` in Elixir
- **AND** the resolved URL SHALL pass the outbound URL policy
- **AND** the persisted delivery row SHALL show the redacted form

#### Scenario: Edge route uses a bot token

- **GIVEN** a Slack channel with `execution_route: :edge_agent`
- **WHEN** it is configured to use `chat.postMessage`
- **THEN** the credential SHALL be injected host-side as `bearer_token`
- **AND** no secret SHALL appear in `params_json`

#### Scenario: Edge route webhook URL travels host-side only

- **GIVEN** a Discord channel with `execution_route: :edge_agent` that must use
  an incoming-webhook URL
- **WHEN** the action is dispatched
- **THEN** the URL SHALL be carried in `host_params_json`
- **AND** the guest SHALL not receive it

#### Scenario: URL-path injection mode is not added

- **WHEN** an implementation proposes a credential injection mode that rewrites
  a URL path segment
- **THEN** it SHALL be rejected as out of scope for this change

### Requirement: Provider Capability Negotiation

A `NotificationChannel` SHALL be validated against its provider's declared
capabilities, routes, and payload formats at write time and again at dispatch
time.

- A channel MUST NOT be assigned an `execution_route` that is absent from the
  provider's `supported_routes`. The create and update actions SHALL reject it,
  and dispatch SHALL refuse to execute it if a stored row somehow holds an
  unsupported combination.
- A provider MUST NOT be asked to render or deliver a `payload_format` it does
  not declare in `payload_formats`. The renderer SHALL negotiate down to a
  declared format using a deterministic preference order, and SHALL record the
  format actually used on the delivery row.
- A route or escalation step MUST NOT request a capability the provider does not
  declare. Requesting `:resolve_update` from a provider without it SHALL be
  rejected rather than silently ignored; requesting `:threading` or
  `:attachments` from a provider without them SHALL degrade to a declared
  behaviour and record that the degradation occurred.
- An inbound acknowledgement callback MUST NOT be registered for a provider that
  does not declare `:inbound_callback`.

Changing a provider's declared `supported_routes`, `payload_formats`, or
`capabilities` SHALL surface every channel that becomes non-conforming, and
SHALL NOT silently break those channels at dispatch time.

#### Scenario: Unsupported route rejected at write time

- **GIVEN** a provider with `supported_routes: [:control_plane]`
- **WHEN** an operator creates a channel with `execution_route: :edge_agent`
- **THEN** the action SHALL fail validation naming the unsupported route

#### Scenario: Unsupported route refused at dispatch time

- **GIVEN** a stored channel whose `execution_route` is not in the provider's
  current `supported_routes`
- **WHEN** a notification is dispatched to it
- **THEN** the delivery SHALL be recorded `:failed` with a capability
  `error_class`
- **AND** no transport call SHALL be made

#### Scenario: Payload format negotiated to a declared format

- **GIVEN** a provider declaring `payload_formats: [:markdown, :plain]`
- **WHEN** the renderer would prefer `:slack_blocks`
- **THEN** it SHALL negotiate down to `:markdown`
- **AND** the delivery row SHALL record the format actually used

#### Scenario: Undeclared capability is not silently ignored

- **WHEN** an escalation step requests `:resolve_update` from a provider that
  does not declare it
- **THEN** the configuration SHALL be rejected with an explicit capability error

#### Scenario: Capability change surfaces non-conforming channels

- **WHEN** a provider's `payload_formats` or `supported_routes` are narrowed
- **THEN** the system SHALL list every channel that no longer conforms
- **AND** SHALL require operator resolution rather than failing silently at the
  next dispatch

### Requirement: Provider Test Send

Every provider SHALL implement a test action, and `:test` SHALL be present in its
`capabilities`. This is mandatory, not optional, for all three extensibility
tiers (`:native`, `:declarative`, `:wasm_plugin`) and for the built-in `:stream`
provider type. `:send` and `:test` together are the minimum capability set;
a provider row or a package manifest `notifications:` entry declaring
`capabilities` without both SHALL be rejected, and there is no
"send-only" provider.

For the `:stream` provider, a test SHALL publish a clearly-marked test envelope
through the same publish path and record the same auditable test result; it is
not exempt from this requirement.

The test action SHALL:

- Exercise the **real** channel configuration and the **real** resolved secrets
  over the **real** execution route, so that a passing test proves the channel
  can deliver.
- Render a clearly-marked test payload using the same restricted templating
  engine and the same payload-format negotiation as a production notification.
- Run without creating an `Alert`, without mutating any alert state, and without
  consuming or advancing deduplication, throttling, escalation, or renotify
  state for any real incident.
- Be invocable from the channel configuration UI before the channel is saved,
  using the submitted-but-unsaved configuration.
- Return a structured result carrying success or failure, the HTTP status or
  command outcome, the negotiated payload format, and a redacted error message
  on failure.
- Record an auditable test result that is distinguishable from a production
  delivery by the `is_test` flag on the recorded row, and that MUST NOT be
  counted toward any alert's delivery or notification counts.
- Enforce every production guard: outbound URL policy for declarative and
  native HTTP egress, capability checks for plugin execution, secret handling
  rules, per-channel rate limiting, and `ActionRedaction` on the recorded
  result.

A test send SHALL respect `fail_closed` and MUST NOT fail over to
`fallback_channel_id`; a test is a statement about one channel.

#### Scenario: Every provider type ships a test action

- **WHEN** a provider of any `provider_type`, including `:stream`, is created or
  activated
- **THEN** it SHALL declare both `:send` and `:test` in `capabilities`
- **AND** a test send SHALL be invocable against a channel bound to it

#### Scenario: Test send exercises real config and secrets

- **WHEN** an operator triggers a test send on a configured channel
- **THEN** the provider SHALL resolve the channel's real secret references
  through `Credentials.SecretBroker`
- **AND** SHALL issue the request over the channel's configured
  `execution_route`

#### Scenario: Test send creates no alert

- **WHEN** a test send runs
- **THEN** no `Alert` SHALL be created or modified
- **AND** no deduplication, throttle, escalation, or renotify state SHALL be
  advanced

#### Scenario: Test before save

- **GIVEN** an operator filling in a new channel form
- **WHEN** they trigger a test send before saving
- **THEN** the test SHALL use the submitted configuration
- **AND** the channel SHALL still not be persisted unless the operator saves it

#### Scenario: Failed test reports a redacted reason

- **WHEN** a test send fails because the destination rejects the credential
- **THEN** the result SHALL report the failure with the status or command
  outcome
- **AND** the recorded error message SHALL have passed `ActionRedaction`

#### Scenario: Test send does not fail over

- **GIVEN** a channel with `fallback_channel_id` set
- **WHEN** a test send to that channel fails
- **THEN** the fallback channel MUST NOT be contacted
- **AND** the result SHALL report the failure for the tested channel only
