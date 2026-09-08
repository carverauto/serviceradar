## ADDED Requirements

### Requirement: Notifier plugin kind

The Go SDK (`github.com/carverauto/serviceradar-sdk-go`) SHALL support a
**notifier** plugin kind that a `NotificationProvider` with `provider_type:
:wasm_plugin` dispatches into, using the same authoring shape as every other
plugin kind in this SDK: a `package main` with `func main() {}` plus one or more
niladic `//export` entrypoints over the hand-written WASI host ABI. The SDK SHALL
NOT require a Go interface, generic type parameter, or `init()` registration to
declare a notifier.

The notifier invocation arrives through the existing `plugin.run_action` command
path, so the host configuration returned by `get_config` SHALL be discriminated
by the presence of a top-level `notification_delivery` key holding a
`serviceradar.notification_delivery_request.v1` document, exactly as
`action_invocation` discriminates a northbound action today. The SDK SHALL
provide `sdk.LoadNotificationRequest()` and `sdk.ParseNotificationRequest([]byte)`
mirroring `LoadActionConfig` / `ParseActionConfig`, returning the typed request
plus the remaining plugin configuration as a separately decodable map.

A notifier plugin SHALL declare the `notify:v1` capability in its package
manifest; the SDK SHALL expose that value as the exported constant
`sdk.CapabilityNotifyV1`, matching the `CapabilityProducerScheduleV1` precedent.

#### Scenario: Notifier entrypoint is a niladic export

- **GIVEN** an author writes `package main` with `func main() {}` and a niladic
  `//export send_notification` function
- **WHEN** the plugin is built with `tinygo build -target=wasi`
- **AND** the agent invokes the exported symbol named in the manifest
  `notifications.entrypoint`
- **THEN** the SDK decodes the host configuration and returns a typed
  `*sdk.NotificationRequest` without the author touching `get_config`, `alloc`,
  `dealloc`, or `submit_result` directly

#### Scenario: Host configuration is discriminated by payload key

- **GIVEN** the host configuration document contains a top-level
  `notification_delivery` key
- **WHEN** the plugin calls `sdk.LoadNotificationRequest()`
- **THEN** the SDK returns the decoded `serviceradar.notification_delivery_request.v1`
  document
- **AND** the remaining keys are returned as the plugin's own configuration,
  decodable through a `DecodePluginConfig(out any)` method

#### Scenario: Host configuration is not a notification delivery

- **GIVEN** the host configuration document has no `notification_delivery` key
- **WHEN** the plugin calls `sdk.LoadNotificationRequest()`
- **THEN** the SDK returns an error the author can test for with
  `errors.Is(err, sdk.ErrNotNotificationRequest)`
- **AND** the plugin may fall back to its check or action entrypoint behaviour

### Requirement: Notification delivery request envelope

The SDK SHALL expose a typed Go struct for
`serviceradar.notification_delivery_request.v1` carrying every field a transport
needs to deliver one attempt, and no field that a transport must not see. The
struct SHALL include at minimum:

- Identity: `schema`, `delivery_id`, `alert_id`, `dedupe_key`, `route_id`,
  `policy_id`, `step_number`, `channel_id`, `provider_key`, `intent`.
  `provider_key` here is the control-plane `NotificationProvider.provider_key`
  attribute, not a manifest key; the manifest `notifications:` block names its
  entry with `key`, and `NotificationProvider.action_key` is what resolves
  against that manifest `key`.
- `alert_snapshot`: the immutable snapshot persisted on `NotificationDelivery`,
  because `Jobs.AlertsRetentionWorker` hard-deletes the alert after a default of
  three days and the delivery outlives it.
- `rendered_payload` plus `payload_format`, where `payload_format` is one of
  `slack_blocks`, `discord_embed`, `markdown`, `plain`, `html`, `pagerduty_v2`,
  or `json`, matching the provider's declared `payload_formats`.
- `channel_config`: the `NotificationChannel.config` values already validated
  against the provider `config_schema`, with every `secretRef` property carrying
  an opaque sentinel rather than material.
- Delivery and attempt metadata: `attempt_count`, `max_attempts`,
  `queued_at`, `started_at`, `next_attempt_at`, `execution_route`
  (`control_plane` or `edge_agent`), `agent_uid`, `command_id`, and the
  `external_correlation_id` recorded by a previous attempt when one exists.
- `action_links`: the signed acknowledge, snooze, and resolve capability links
  minted per delivery by the control plane.

The SDK SHALL provide accessor helpers rather than requiring map traversal, at
minimum `(*NotificationRequest).ActionLink(action string)`,
`(*NotificationRequest).IsRetry()`, and
`(*NotificationRequest).DecodeChannelConfig(out any)`.

The SDK SHALL NOT expose any field, method, or side channel that yields resolved
secret material, because secrets MUST NOT enter Wasm guest memory.

#### Scenario: Request envelope decodes with a rendered payload and format

- **GIVEN** the host supplies a `serviceradar.notification_delivery_request.v1`
  document with `payload_format` `slack_blocks` and a rendered payload
- **WHEN** the plugin calls `sdk.LoadNotificationRequest()`
- **THEN** `req.PayloadFormat` is `sdk.PayloadFormatSlackBlocks`
- **AND** `req.RenderedPayload` contains the payload bytes unmodified

#### Scenario: Retry attempt carries prior correlation

- **GIVEN** a delivery whose first attempt returned `external_correlation_id`
  `1700000000.000100` and whose `attempt_count` is `2`
- **WHEN** the plugin decodes the request
- **THEN** `req.IsRetry()` returns true
- **AND** `req.ExternalCorrelationID` is `1700000000.000100` so the transport can
  update rather than duplicate the destination message

#### Scenario: Alert snapshot is present even when the alert is gone

- **GIVEN** an escalation step firing after `Jobs.AlertsRetentionWorker` deleted
  the originating alert row
- **WHEN** the plugin decodes the request
- **THEN** `req.AlertSnapshot` is populated from the delivery record
- **AND** the plugin can render a complete notification without any further host
  call

#### Scenario: Action links are exposed by action name

- **GIVEN** a request carrying acknowledge, snooze, and resolve links
- **WHEN** the plugin calls `req.ActionLink("acknowledge")`
- **THEN** the SDK returns the link URL, label, and expiry
- **AND** the SDK provides no API to mint, sign, derive, or extend such a link

### Requirement: Notification delivery result envelope

The SDK SHALL expose a typed result for
`serviceradar.notification_delivery_result.v1` with exactly three terminal
statuses, exported as `sdk.NotificationDelivered`, `sdk.NotificationFailed`, and
`sdk.NotificationRetryable`, plus the fields `external_correlation_id`,
`error_class`, `error_message`, `result_summary`, and `retry_after_seconds`.

The SDK SHALL provide constructors and a submit helper mirroring the northbound
action surface: `sdk.NotificationDeliveredResult(...)`,
`sdk.NotificationFailedResult(class, message)`,
`sdk.NotificationRetryableResult(class, message)`, and
`sdk.SubmitNotificationResult(*NotificationResult)`.

Status semantics SHALL be normative and non-overlapping, because the control
plane maps them onto `NotificationDelivery` state:

- `delivered` means the destination accepted the notification; core records
  `state: :sent`.
- `failed` means the attempt failed and retrying cannot help; core records
  `state: :failed` and stops retrying, then applies transport failover to
  `fallback_channel_id` unless the channel is `fail_closed`.
- `retryable` means the attempt failed transiently (5xx, timeout, or 429); core
  records the failure, honours `retry_after_seconds` as a lower bound on
  `next_attempt_at`, and retries while `attempt_count` is below `max_attempts`.

A plugin that returns no result, or whose result omits `status`, SHALL be treated
by the SDK submit helper as `failed` with `error_class` `plugin_no_result`, so a
silent guest exit never reads as a successful page.

#### Scenario: Successful delivery returns a correlation id

- **GIVEN** a transport that posted a message and received message id `abc123`
- **WHEN** the plugin returns
  `sdk.NotificationDeliveredResult().WithCorrelationID("abc123")`
- **THEN** the serialized payload has `status` `delivered` and
  `external_correlation_id` `abc123`
- **AND** the control plane records the delivery as `:sent` with that
  `external_correlation_id`

#### Scenario: Transient failure is reported as retryable

- **GIVEN** the destination returned HTTP 429 with `Retry-After: 30`
- **WHEN** the plugin returns
  `sdk.NotificationRetryableResult("rate_limited", "429 from provider").WithRetryAfterSeconds(30)`
- **THEN** the serialized payload has `status` `retryable`, `error_class`
  `rate_limited`, and `retry_after_seconds` `30`

#### Scenario: Permanent failure is reported as failed

- **GIVEN** the destination returned HTTP 404 for a deleted channel
- **WHEN** the plugin returns
  `sdk.NotificationFailedResult("channel_not_found", "404 channel_not_found")`
- **THEN** the serialized payload has `status` `failed`
- **AND** the control plane does not schedule a further attempt for this delivery

#### Scenario: Plugin exits without submitting a result

- **GIVEN** a notifier entrypoint that returns without calling
  `sdk.SubmitNotificationResult`
- **WHEN** the SDK execution wrapper finalizes the invocation
- **THEN** the SDK submits `status` `failed` with `error_class`
  `plugin_no_result`

### Requirement: Notifier intents and capability-gated behaviour

The request envelope `intent` field SHALL be one of `send`, `resolve_update`, or
`test`, and the SDK SHALL expose these as typed constants plus a
`(*NotificationRequest).Intent()` accessor.

Every notifier SHALL declare both `send` and `test` in its manifest
`notifications.capabilities` and SHALL handle both the `send` and the `test`
intent. A test action is mandatory for every provider in every tier, so a
manifest whose `capabilities` omits `send` or omits `test` is rejected by the SDK
validation helper and by the platform manifest validator. `resolve_update` is
the only optional intent, and a notifier SHALL receive it only when it declared
the `resolve_update` capability. The SDK manifest validation helper SHALL reject
a manifest that omits a capability the plugin's declared behaviour depends on,
and the SDK runtime helper SHALL return an error rather than guessing when it
receives an intent the manifest did not declare.

#### Scenario: Resolve update reuses the original correlation id

- **GIVEN** an alert transitions to resolved and the provider declared the
  `resolve_update` capability
- **WHEN** the plugin receives a request with `intent` `resolve_update` and a
  populated `external_correlation_id`
- **THEN** the plugin can update the original destination message rather than
  post a new one

#### Scenario: Test send is distinguishable from a real page

- **GIVEN** an operator uses test-send from the channel settings screen
- **WHEN** the plugin receives a request with `intent` `test`
- **THEN** `req.Intent()` returns `sdk.NotificationIntentTest`
- **AND** the plugin can suppress paging semantics such as PagerDuty incident
  creation while still exercising the transport

#### Scenario: Send and test intents are never refused as undeclared

- **GIVEN** any manifest that passed SDK validation, which therefore declares
  both `send` and `test`
- **WHEN** the plugin receives a request with `intent` `send` or `intent` `test`
- **THEN** the SDK dispatches it as a declared intent
- **AND** the SDK never returns a missing-capability error for `send` or `test`

#### Scenario: Undeclared intent is refused

- **GIVEN** a manifest whose `notifications.capabilities` omits `resolve_update`
- **WHEN** the plugin receives a request with `intent` `resolve_update`
- **THEN** the SDK returns an error identifying the missing capability
- **AND** the SDK does not silently downgrade the intent to `send`

### Requirement: Credential-broker helpers for notifier outbound HTTP

The SDK SHALL provide notifier-facing helpers over the `http_request` host
function that let an author authenticate an outbound request **without ever
holding secret material in guest memory**. Secret-bearing channel configuration
SHALL be represented by an opaque `sdk.SecretRef` type constructed only by the
SDK from a host-supplied sentinel, and:

- `SecretRef` SHALL NOT expose the underlying value; its `String()`,
  `MarshalJSON`, and `%v`/`%s` formatting SHALL render a redacted placeholder,
  never the sentinel or any material.
- `SecretRef` SHALL be attachable to an outbound request only as an **injection
  intent** (`sdk.WithCredentialInjection(ref, sdk.InjectBearerToken)` and
  equivalents for HTTP header, basic auth, query parameter, form field, and
  OAuth2 password bearer), which the SDK serializes into the host request payload
  for the agent to resolve through the matching `CredentialBrokerGrant`.
- The SDK SHALL support exactly the six injection modes the agent implements
  today, under exactly these canonical wire names: `http_header`,
  `bearer_token`, `basic_auth`, `query`, `form_urlencoded`, and
  `oauth2_password_bearer` (`go/pkg/agent/plugin_runtime_actions.go` for the
  first five, `go/pkg/agent/plugin_runtime_http.go` for the sixth). They SHALL be
  exposed as `sdk.InjectHTTPHeader`, `sdk.InjectBearerToken`,
  `sdk.InjectBasicAuth`, `sdk.InjectQuery`, `sdk.InjectFormURLEncoded`, and
  `sdk.InjectOAuth2PasswordBearer`. The SDK SHALL NOT emit the abbreviations
  `bearer`, `basic`, `header`, or `form` as mode names, and SHALL return
  `sdk.ErrUnsupportedInjection` for any other mode, including URL path
  interpolation, which no injection mode rewrites.
- The SDK SHALL refuse to place a `SecretRef` into a request URL, header value,
  or body by string concatenation, returning an error rather than emitting the
  sentinel onto the wire.

The SDK SHALL document that Slack and Discord incoming-webhook URLs carry their
secret in the URL path and are therefore unsupported on the `edge_agent` route;
authors SHALL use a bot-token API with `bearer_token` injection, or the
trusted-host-only `host_params_json` field, instead.

#### Scenario: Bearer token injection never enters guest memory

- **GIVEN** channel configuration whose `api_token_secret_ref` property carries a
  `secretref:` sentinel
- **WHEN** the plugin builds a request with
  `sdk.WithCredentialInjection(cfg.APIToken, sdk.InjectBearerToken)` and calls the
  notifier HTTP helper
- **THEN** the request the SDK hands to `http_request` carries an injection
  directive and no credential value
- **AND** the agent resolves the grant host-side and sets the `Authorization`
  header before the request leaves the host

#### Scenario: Secret reference cannot be printed or logged

- **GIVEN** a plugin that calls `sdk.Log.Info(fmt.Sprintf("token=%v", ref))`
- **WHEN** the SDK formats the `SecretRef`
- **THEN** the emitted text contains a redacted placeholder
- **AND** it contains neither the sentinel string nor any credential material

#### Scenario: URL path injection is rejected

- **GIVEN** a plugin that requests `sdk.InjectURLPath` for a Slack incoming
  webhook on the `edge_agent` route
- **WHEN** the SDK validates the injection intent
- **THEN** the SDK returns `sdk.ErrUnsupportedInjection`
- **AND** the error message names the supported alternatives

#### Scenario: Grant is denied by the agent

- **GIVEN** an injection intent whose grant does not allow the requested host or
  method
- **WHEN** the host rejects the request
- **THEN** the SDK surfaces a typed error the plugin can map to
  `sdk.NotificationFailedResult("credential_denied", ...)`
- **AND** the SDK does not retry the request itself

### Requirement: Notifier configuration decoding against the manifest config schema

The SDK SHALL provide `(*NotificationRequest).DecodeChannelConfig(out any)` which
decodes `channel_config` into a caller-supplied Go struct, and SHALL:

- Decode any property the manifest `notifications.config_schema` declares as a
  `secretRef` property into an `sdk.SecretRef` field rather than a `string`,
  returning an error if the target field is a plain `string`.
- Preserve the sentinel opaquely, so a plugin can pass it back as an injection
  intent but can never read it.
- Provide `sdk.ValidateChannelConfig(schema, config)` that checks required
  properties, declared types, and enumerated values against the same JSON Schema
  subset `ServiceRadar.Plugins.ConfigSchema` accepts, so an author can fail fast
  locally rather than discovering a mismatch at dispatch time.
- Return a decoding error, never a partially populated struct, when
  `channel_config` is not valid against the declared schema.

#### Scenario: Secret-bearing property decodes to an opaque reference

- **GIVEN** a config schema declaring `api_token_secret_ref` as a `secretRef`
  property
- **WHEN** the plugin decodes the channel config into a struct with an
  `sdk.SecretRef` field
- **THEN** the field holds an opaque reference usable only as an injection intent

#### Scenario: Secret property decoded into a string is refused

- **GIVEN** the same schema and a target struct declaring `APIToken string`
- **WHEN** the plugin calls `DecodeChannelConfig`
- **THEN** the SDK returns an error naming the offending field
- **AND** no sentinel or material is written into the struct

#### Scenario: Config fails schema validation

- **GIVEN** a channel config missing a property the schema marks required
- **WHEN** the plugin calls `sdk.ValidateChannelConfig(schema, config)`
- **THEN** the SDK returns an error naming the missing property

### Requirement: Notifications manifest contract builder and validator

The SDK SHALL provide a manifest contract builder for the `notifications:` block
of `plugin.yaml`, following the `ProducerScheduleContract` and `CheckDescriptor`
precedent: a `sdk.NotificationProviderContract` struct with fluent `With...`
methods, JSON tags matching the manifest keys, and a `Validate() error` method.

The contract SHALL carry exactly the manifest keys the platform manifest
validator owns, and no others: `key`, `display_name`, `description`,
`entrypoint`, `config_schema`, `capabilities`, `payload_formats`, `routes`,
`credential_requirements`, and `inbound`. Go struct field names may be
idiomatic, but the JSON and YAML tags SHALL be exactly those key names. The SDK
SHALL NOT emit `provider_key`, `supported_routes`, or `inbound_callback` as
manifest keys, because the platform manifest validator rejects an unknown key in
the `notifications:` block. `provider_key` remains the name of the control-plane
`NotificationProvider` attribute and of the corresponding request-envelope
field; it is not a manifest key. The manifest `key` value is the value a
`NotificationProvider.action_key` resolves against for a `:wasm_plugin`
provider, so it is the join between the package manifest and the provider row.

`Validate()` SHALL reject, with a specific error naming the offending value:

- a `key` that is empty or not a lowercase, underscore-or-hyphen slug;
- an empty `entrypoint`;
- an empty `display_name`;
- a `capabilities` list that omits `send` or omits `test`, because every provider
  in every tier SHALL implement a test action and SHALL declare `test`, and the
  platform manifest validator rejects a `capabilities` list missing either;
- any capability outside `send`, `test`, `resolve_update`, `inbound_callback`,
  `rich_payload`, `attachments`, `threading`;
- any payload format outside `slack_blocks`, `discord_embed`, `markdown`,
  `plain`, `html`, `pagerduty_v2`, `json`;
- any entry in `routes` outside `control_plane`, `edge_agent`;
- any entry in `credential_requirements` whose injection mode is outside
  `http_header`, `bearer_token`, `basic_auth`, `query`, `form_urlencoded`,
  `oauth2_password_bearer`;
- a contract declaring the `inbound_callback` capability with no `inbound`
  configuration, or an `inbound` configuration with no `inbound_callback`
  capability;
- any object **key** anywhere in the block named `html`, `raw_html`,
  `javascript`, `js`, `component`, `component_ref`, `live_view`, `react`, or
  `ui_code`, matching the hard rejection the platform manifest validator already
  performs, since providers describe their UI declaratively and never ship
  markup. The `html` token appearing as a value in the enumerated
  `payload_formats` list is not a key and SHALL remain valid.

The SDK SHALL provide `sdk.RenderNotificationsManifestBlock(contract)` emitting
the YAML-serializable map for the `notifications:` block keyed by exactly `key`,
`display_name`, `description`, `entrypoint`, `config_schema`, `capabilities`,
`payload_formats`, `routes`, `credential_requirements`, and `inbound`, so an
author generates the block from the same struct the runtime helpers consume, the
emitted block is accepted by the platform manifest validator unchanged, and the
two cannot drift.

#### Scenario: Valid contract renders a manifest block

- **GIVEN** an author builds a contract with `key` `mattermost`, entrypoint
  `send_notification`, capabilities `send` and `test`, payload formats
  `markdown` and `json`, and `routes` `["control_plane"]`
- **WHEN** the author calls `Validate()` and
  `sdk.RenderNotificationsManifestBlock(contract)`
- **THEN** validation passes
- **AND** the rendered map matches the `notifications:` block the platform
  manifest validator accepts

#### Scenario: Rendered block uses only canonical manifest keys

- **GIVEN** any contract that passes `Validate()`
- **WHEN** the author calls `sdk.RenderNotificationsManifestBlock(contract)`
- **THEN** the rendered entry's keys are drawn only from `key`, `display_name`,
  `description`, `entrypoint`, `config_schema`, `capabilities`,
  `payload_formats`, `routes`, `credential_requirements`, and `inbound`
- **AND** the rendered entry contains no `provider_key`, `supported_routes`, or
  `inbound_callback` key
- **AND** the platform manifest validator accepts the rendered entry without
  rewriting any key

#### Scenario: Capabilities omitting test are rejected

- **GIVEN** a contract declaring `capabilities` of `["send"]`
- **WHEN** the author calls `Validate()`
- **THEN** the SDK returns an error stating that `test` is mandatory for every
  provider
- **AND** the rendered manifest block is not produced

#### Scenario: Capabilities omitting send are rejected

- **GIVEN** a contract declaring `capabilities` of `["test"]`
- **WHEN** the author calls `Validate()`
- **THEN** the SDK returns an error stating that `send` is mandatory for every
  provider

#### Scenario: Unknown capability is rejected

- **GIVEN** a contract declaring the capability `sms_burst`
- **WHEN** the author calls `Validate()`
- **THEN** the SDK returns an error naming `sms_burst` and listing the allowed
  capability set

#### Scenario: Markup key is rejected

- **GIVEN** a contract whose `config_schema` contains a nested `ui_code` key
- **WHEN** the author calls `Validate()`
- **THEN** the SDK returns an error naming the `ui_code` key
- **AND** the rendered manifest block is not produced

#### Scenario: Unsupported route is rejected

- **GIVEN** a contract declaring `routes` of `["site_relay"]`
- **WHEN** the author calls `Validate()`
- **THEN** the SDK returns an error naming `site_relay`

#### Scenario: Non-canonical injection mode in a credential requirement is rejected

- **GIVEN** a contract whose `credential_requirements` declares the injection
  mode `bearer`
- **WHEN** the author calls `Validate()`
- **THEN** the SDK returns an error naming `bearer` and listing
  `http_header`, `bearer_token`, `basic_auth`, `query`, `form_urlencoded`, and
  `oauth2_password_bearer` as the canonical modes

### Requirement: Example notifier plugin in the SDK repository

The `serviceradar-sdk-go` repository SHALL ship an `examples/notifier/` plugin
demonstrating the complete notifier authoring path in the repository's existing
example shape: `main.go` guarded by `//go:build tinygo` with a niladic `//export`
entrypoint and `func main() {}`, plus a `main_stub.go` guarded by
`//go:build !tinygo`, matching `examples/sample-northbound/`.

The example SHALL show, end to end: decoding the request with
`sdk.LoadNotificationRequest()`, decoding channel config containing a
`secretRef` property, performing an authenticated outbound POST using a
credential injection intent under a canonical injection mode, rendering the
action links into the message body, handling both the mandatory `send` and
`test` intents, and returning each of `delivered`, `retryable`, and `failed` on
the appropriate transport outcome. The example `plugin.yaml` `notifications:`
block SHALL be generated by `sdk.RenderNotificationsManifestBlock`, so it uses
the canonical manifest keys (`key`, `display_name`, `description`, `entrypoint`,
`config_schema`, `capabilities`, `payload_formats`, `routes`,
`credential_requirements`, `inbound`) and declares `send` and `test` in
`capabilities`.

The example SHALL be listed in the repository `README.md` example list alongside
`examples/http-check`, `examples/tcp-check`, `examples/udp-check`,
`examples/widgets-check`, and `examples/sample-northbound`, and SHALL build under
`tinygo build -o plugin.wasm -target=wasi ./`.

#### Scenario: Example builds for wasi

- **GIVEN** the `examples/notifier` directory
- **WHEN** a developer runs `tinygo build -o plugin.wasm -target=wasi ./`
- **THEN** the build succeeds and produces a module exporting the notifier
  entrypoint, `alloc`, and `dealloc`

#### Scenario: Example never handles raw secret material

- **GIVEN** the example source
- **WHEN** it is reviewed for credential handling
- **THEN** every authenticated request uses a credential injection intent
- **AND** no code path reads, decrypts, concatenates, or logs a credential value

### Requirement: Fixture-based notifier conformance test

The `serviceradar-sdk-go` repository SHALL add stable JSON fixtures under
`fixtures/` for the notifier contract, following the existing
`northbound_action_*.json` convention, covering at minimum:

- `notification_delivery_request.json` (a `send` intent with action links,
  channel config containing a `secretRef` sentinel, and a populated
  `alert_snapshot`);
- `notification_delivery_retry_request.json` (`attempt_count` above one with a
  prior `external_correlation_id`);
- `notification_delivery_result_delivered.json`,
  `notification_delivery_result_retryable.json`, and
  `notification_delivery_result_failed.json`;
- `notification_provider_contract.json` (the rendered `notifications:` block,
  keyed by exactly `key`, `display_name`, `description`, `entrypoint`,
  `config_schema`, `capabilities`, `payload_formats`, `routes`,
  `credential_requirements`, and `inbound`, with `capabilities` containing at
  least `send` and `test`).

The SDK SHALL carry a conformance test that decodes each request fixture, asserts
the typed accessors, re-encodes each result fixture, and asserts byte-stable
round-tripping of every field the control plane persists. The fixtures SHALL be
the **shared corpus** for both SDKs: the identical files SHALL exist in
`serviceradar-sdk-rust/fixtures/` and both conformance suites SHALL assert
against them, so a divergence in either SDK fails a test rather than reaching the
wire.

`fixtures/README.md` SHALL state that these files are test fixtures, not runtime
defaults, and that real values are produced by ServiceRadar when a delivery is
dispatched.

#### Scenario: Request fixture round-trips

- **GIVEN** `fixtures/notification_delivery_request.json`
- **WHEN** the conformance test decodes it into `sdk.NotificationRequest` and
  re-encodes it
- **THEN** every field is preserved, including `alert_snapshot`, `action_links`,
  and the `secretRef` sentinel in `channel_config`

#### Scenario: Result fixtures cover all three statuses

- **WHEN** the conformance test encodes the delivered, retryable, and failed
  results
- **THEN** each matches its fixture exactly, including `error_class`,
  `error_message`, `external_correlation_id`, and `retry_after_seconds`

#### Scenario: Shared corpus divergence fails a test

- **GIVEN** a change to a field name in the Go SDK notifier structs
- **WHEN** the shared fixtures are unchanged
- **THEN** the Go conformance test fails
- **AND** the Rust conformance test asserting the same fixtures also fails

### Requirement: Rust SDK notifier parity

The Rust SDK (`serviceradar-sdk-rust`, crate `serviceradar_sdk_rust`) SHALL
expose an equivalent notifier surface with wire semantics identical to the Go
SDK: the same `serviceradar.notification_delivery_request.v1` and
`serviceradar.notification_delivery_result.v1` schema strings, the same field
names and JSON shapes, the same three result statuses (`delivered`, `failed`,
`retryable`), the same `notify:v1` capability constant, the same six canonical
injection modes (`http_header`, `bearer_token`, `basic_auth`, `query`,
`form_urlencoded`, `oauth2_password_bearer`), the same canonical manifest keys
(`key`, `display_name`, `description`, `entrypoint`, `config_schema`,
`capabilities`, `payload_formats`, `routes`, `credential_requirements`,
`inbound`) with the same mandatory `send` and `test` capabilities, and the same
opaque secret-reference guarantees.

The Rust SDK today is a thin, idiomatic wrapper over the imported `env` host ABI
functions, exposing free functions plus typed payload structs and **no plugin
trait**; the notifier surface SHALL follow that same shape rather than
introducing a trait, so a Rust notifier is a `#[unsafe(no_mangle)] pub extern
"C" fn` entrypoint calling free functions such as `load_notification_request`,
`submit_notification_result`, and the credential-injection request builders. The
Rust API SHALL be idiomatic (snake_case, `Result`, typed enums) rather than a
line-for-line Go port, while the serialized bytes SHALL be identical.

The Rust SDK SHALL ship an equivalent notifier example and the shared fixture
corpus conformance test described above.

#### Scenario: Both SDKs produce identical bytes for the same result

- **GIVEN** the same delivered result with the same correlation id
- **WHEN** the Go SDK and the Rust SDK each serialize it
- **THEN** the two payloads are semantically identical field for field
- **AND** both match `fixtures/notification_delivery_result_delivered.json`

#### Scenario: Both SDKs render the same manifest keys

- **GIVEN** the same notifier contract expressed in each SDK
- **WHEN** each renders the `notifications:` block
- **THEN** both emit exactly `key`, `display_name`, `description`, `entrypoint`,
  `config_schema`, `capabilities`, `payload_formats`, `routes`,
  `credential_requirements`, and `inbound`
- **AND** neither emits `provider_key`, `supported_routes`, or
  `inbound_callback` as a key
- **AND** both match `fixtures/notification_provider_contract.json`

#### Scenario: Rust notifier needs no plugin trait

- **GIVEN** a Rust author writing a notifier
- **WHEN** they follow the crate documentation
- **THEN** the entrypoint is an exported `extern "C"` function calling free SDK
  functions
- **AND** no trait implementation or registration macro is required

#### Scenario: Rust SDK refuses unsupported injection

- **GIVEN** a Rust plugin requesting URL-path credential injection
- **WHEN** the SDK validates the injection intent
- **THEN** it returns the same error class as the Go SDK's
  `ErrUnsupportedInjection`

### Requirement: Joint notifier contract versioning and release of both SDKs

Both SDKs SHALL export a single notifier contract version constant
(`sdk.NotifierContractVersion` in Go, `NOTIFIER_CONTRACT_VERSION` in Rust) whose
value is identical, and SHALL emit it as `sdk_contract_version` on the result
envelope so the agent and the control plane can detect a mismatch at dispatch
time rather than in production.

A change to any notifier request field, result field, status value, injection
mode, capability token, or manifest key SHALL be released in **both** SDKs
together, under the same contract version, before any first-party plugin adopts
it. Neither repository SHALL tag a release advancing the notifier contract
version alone.

The agent SHALL reject a notifier result whose `sdk_contract_version` has a major
component the agent does not support, recording it as
`error_class` `sdk_contract_mismatch`, rather than accepting a partially
understood payload.

#### Scenario: Contract change released in both SDKs

- **GIVEN** a new optional field is added to the notifier result envelope
- **WHEN** the change is released
- **THEN** both `serviceradar-sdk-go` and `serviceradar-sdk-rust` publish a
  release carrying the same `NotifierContractVersion`
- **AND** the shared fixture corpus is updated once and asserted by both suites

#### Scenario: Mismatched contract major is rejected

- **GIVEN** a plugin built against a notifier contract major the agent does not
  support
- **WHEN** it submits a result
- **THEN** the agent records the delivery attempt as failed with `error_class`
  `sdk_contract_mismatch`
- **AND** the delivery does not report as `sent`

### Requirement: SDK version pinning across in-repo Wasm plugins

Every notifier-bearing plugin module SHALL pin an SDK version that supports the
notifier contract version its manifest targets. Each module under
`go/cmd/wasm-plugins/` carries its own `go.mod`
pinning `github.com/carverauto/serviceradar-sdk-go` independently -- the
nine modules present today pin four different pseudo-versions -- so a notifier
contract that lands in the SDK is not automatically present in any plugin.

This change SHALL add a repository gate that verifies every module under
`go/cmd/wasm-plugins/` whose `plugin.yaml` declares a `notifications:` block pins
an SDK version at or above the release that introduced the notifier contract
version that module's manifest targets, and fails the build with the offending
module path and pinned version when it does not. Plugins that declare no
`notifications:` block SHALL remain free to pin an older SDK.

Bumping the SDK pin for a notifier-bearing module SHALL be part of the same
change that adopts a new notifier contract version, so an in-repo plugin cannot
ship a manifest the pinned SDK cannot produce or parse.

#### Scenario: Notifier plugin pins a stale SDK

- **GIVEN** a module under `go/cmd/wasm-plugins/` declaring a `notifications:`
  block and pinning an SDK version predating the notifier contract
- **WHEN** the repository gate runs
- **THEN** the gate fails naming the module path and the pinned version
- **AND** it names the minimum SDK version required

#### Scenario: Non-notifier plugin keeps its existing pin

- **GIVEN** a module under `go/cmd/wasm-plugins/` with no `notifications:` block
  pinning an older SDK pseudo-version
- **WHEN** the repository gate runs
- **THEN** the gate passes and does not require a bump

### Requirement: Notifier logging and payload redaction safety

The SDK SHALL NOT log, and SHALL NOT provide a helper that logs, the
`rendered_payload`, `channel_config`, `alert_snapshot`, or any `action_links`
value through the `log` host function by default, because every notification
payload and log line is subject to the platform redaction policy before
persistence or display, and the guest cannot apply it.

SDK-generated error strings surfaced in `error_message` SHALL be bounded in
length and SHALL NOT interpolate a `SecretRef`, a credential injection value, or
a full action link URL. The SDK SHALL provide
`sdk.RedactedRequestSummary(*NotificationRequest)` returning identity fields
only (`delivery_id`, `alert_id`, `channel_id`, `provider_key`, `intent`,
`attempt_count`) for safe author-side logging.

#### Scenario: Author logs a request summary

- **GIVEN** a plugin calling `sdk.Log.Info(sdk.RedactedRequestSummary(req))`
- **WHEN** the log reaches the agent
- **THEN** it contains only identity fields
- **AND** it contains no rendered payload, channel config, action link, or
  secret reference

#### Scenario: Error message excludes an action link

- **GIVEN** a transport failure while posting a body containing an acknowledge
  link
- **WHEN** the SDK builds the `error_message`
- **THEN** the message is truncated to the documented bound
- **AND** it contains no action link URL or capability token

## MODIFIED Requirements

### Requirement: Configuration decoding
The SDK MUST load the plugin configuration JSON provided by the host and decode it into a caller-supplied Go struct. When the plugin manifest declares a property as a `secretRef` property, the host-supplied configuration carries an opaque sentinel in place of the credential, and the SDK MUST preserve that sentinel opaquely: it MUST NOT resolve it, MUST NOT expose its contents to plugin code, and MUST NOT include it in any log line, error string, or serialized result. Decoding a `secretRef` property into a plain `string` field MUST return an error rather than surfacing the sentinel value.

#### Scenario: Configuration JSON decodes successfully
- **GIVEN** the host provides valid JSON configuration
- **WHEN** the plugin calls `GetConfig(&cfg)`
- **THEN** the SDK populates `cfg` with the decoded values

#### Scenario: Configuration JSON is invalid
- **GIVEN** the host provides invalid JSON configuration
- **WHEN** the plugin calls `GetConfig(&cfg)`
- **THEN** the SDK returns a decoding error

#### Scenario: Secret reference property is preserved opaquely
- **GIVEN** the host provides configuration whose `api_token_secret_ref` property carries a `secretref:` sentinel
- **WHEN** the plugin decodes it into a struct field of type `sdk.SecretRef`
- **THEN** the SDK populates the field with an opaque reference
- **AND** no API on that reference returns the sentinel string or any credential material

#### Scenario: Secret reference decoded into a plain string
- **GIVEN** the same configuration and a target struct declaring the field as `string`
- **WHEN** the plugin calls `GetConfig(&cfg)`
- **THEN** the SDK returns an error naming the offending field
- **AND** the field is left unset

### Requirement: Host function wrappers
The SDK MUST expose Go-friendly wrappers for host functions, including HTTP requests and stream-oriented connections, without direct syscalls. Outbound HTTP wrappers MUST additionally support declaring a credential injection intent that references an opaque `sdk.SecretRef`, so that authentication material is resolved and applied host-side through the matching credential broker grant and never enters guest memory. The wrappers MUST support exactly the six injection modes the agent implements, under their canonical wire names (`http_header`, `bearer_token`, `basic_auth`, `query`, `form_urlencoded`, `oauth2_password_bearer`), MUST NOT emit the abbreviations `bearer`, `basic`, `header`, or `form`, and MUST return an error for any other mode, including URL path interpolation.

#### Scenario: HTTP wrapper performs a request
- **GIVEN** a plugin calls `sdk.HTTP.Get("https://example.com/health")`
- **WHEN** the host function executes
- **THEN** the SDK returns the response status, body, and timing data

#### Scenario: Stream wrapper provides I/O
- **GIVEN** a plugin opens a TCP stream through the SDK
- **WHEN** it writes and reads data
- **THEN** the SDK forwards I/O through host functions and returns the response

#### Scenario: HTTP wrapper carries a credential injection intent
- **GIVEN** a plugin builds a request with `sdk.WithCredentialInjection(ref, sdk.InjectBearerToken)`
- **WHEN** the SDK serializes the request for the `http_request` host function
- **THEN** the serialized request carries the injection directive and no credential value
- **AND** the agent applies the credential from the matching grant before the request leaves the host

#### Scenario: Unsupported injection mode is refused
- **GIVEN** a plugin requests URL path injection for a webhook whose secret is in the path
- **WHEN** the SDK validates the request
- **THEN** the SDK returns `sdk.ErrUnsupportedInjection`
- **AND** the request is not sent to the host
