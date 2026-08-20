## ADDED Requirements

### Requirement: Runtime resolution of package-shipped display contracts

`ServiceRadarWebNG.Observability.SignalDisplay.resolve_contract/2` SHALL resolve a
display contract at render time from data persisted with the plugin or add-on
package, and SHALL NOT require the contract document to be present in the
web-ng source tree at compile time.

Today `@built_in_contracts` (`signal_display.ex:68-83`) is a compile-time map of
seven map entries built by `File.read!` over six distinct hardcoded first-party
paths - the `powerdns` `0.1.0` and `0.1.1` producer-version keys resolve to the
same path, so the entry count exceeds the path count by one. The six paths are
`addons/powerdns/display/dns_activity.display.json`,
`go/cmd/wasm-plugins/axis/display/event_log_activity.display.json`,
`go/cmd/wasm-plugins/unifi-protect/display/camera_event.display.json`,
`go/cmd/wasm-plugins/proxmox/display/resource_event.display.json`,
`go/pkg/trivysidecar/display/vulnerability_report.display.json`, and
`integrations/falco/display/runtime_event.display.json`. At render time
`resolve_contract/2` consults only that map plus the
`Application.get_env(:serviceradar_web_ng, SignalDisplay)[:contracts]` override.
The `PluginPackage.display_contract` map and `PluginPackage.signal_schemas`
array (`plugin_package.ex:201`, `plugin_package.ex:207`), which the importer
already persists from the manifest, are never read at render time. A
third-party package therefore cannot ship a renderable display contract without
recompiling web-ng.

The resolution order SHALL be:

1. the explicit `:contracts` option or application-environment override, for
   tests and operator break-glass;
2. the contract persisted with the package version whose
   `signal_schemas[]` entry matches the record's
   `{producer_id, producer_version, schema_id, schema_version}` key;
3. the compile-time first-party map, used **only** as a fallback for packages
   that ship no contract of their own.

Resolution SHALL match on the exact four-part key first and SHALL fall back to
`{producer_id, schema_id, schema_version}` ignoring `producer_version`, which is
the existing `built_in_contract/1` behaviour. Resolution SHALL be served from a
bounded in-memory cache keyed by package version identity, and that cache entry
SHALL be invalidated when the package version's `display_contract` or
`signal_schemas` changes so that an imported or upgraded package renders without
a web-ng restart.

#### Scenario: Third-party package contract renders without a release

- **GIVEN** an uploaded plugin package version whose manifest declares a
  `signal_schemas[]` entry with `display_contract`, `display_contract_id`, and
  `display_contract_version`, and whose contract document is persisted with the
  package
- **AND** the package's producer identity appears in no compile-time map in
  web-ng
- **WHEN** an operator opens an event or log record emitted by that package
- **THEN** `SignalDisplay.resolve_contract/2` SHALL return the package-shipped
  contract
- **AND** the record SHALL render through it with no change to web-ng source and
  no recompilation

#### Scenario: Compile-time map is fallback only

- **GIVEN** a first-party package whose producer identity is present in
  `@built_in_contracts`
- **WHEN** that package version is reimported carrying its own persisted
  display contract
- **THEN** the persisted contract SHALL be used
- **AND** the compile-time entry SHALL be used only when the package version
  persists no contract

#### Scenario: Upgrading a package refreshes the rendered contract

- **WHEN** a package version is imported or upgraded and its persisted
  `display_contract` or `signal_schemas` differs from the cached value
- **THEN** the cached resolution for that package version SHALL be invalidated
- **AND** the next render SHALL use the newly persisted contract without
  restarting web-ng

#### Scenario: Operator override still wins

- **GIVEN** a `:contracts` entry supplied through application environment for a
  producer identity that also has a persisted package contract
- **WHEN** a record for that identity is rendered
- **THEN** the configured override SHALL be used

### Requirement: Display contract versioning and import-time validation

A package-shipped display contract SHALL be validated when the package is
imported, not when it is rendered. Validation SHALL reject the package version
with field-level errors rather than persisting a contract that fails at render
time.

Validation SHALL enforce:

- a declared contract schema version, carried as
  `signal_schemas[].display_contract_version`, that the running web-ng
  recognises; an unrecognised major version SHALL be rejected at import with an
  explicit message naming the supported versions;
- `signal_schemas[].display_contract_id` is a stable identifier and
  `signal_schemas[].display_contract` is a relative path inside the package
  bundle, both already required by `ServiceRadar.Plugins.Manifest`
  (`manifest.ex:587-609`);
- the contract document is a JSON object whose top-level keys are drawn from a
  documented allowlist, and whose `widgets[]` entries declare a `type` in the
  supported widget set (`summary`, `facts`, `badges`, `timeline`,
  `json_section`, `table`);
- every widget field path is a whitelisted read of the record, and no field path
  can escape the record into module, process, or environment state;
- the document contains none of the forbidden UI keys already rejected for
  action descriptors - `html`, `raw_html`, `javascript`, `js`, `component`,
  `component_ref`, `live_view`, `react`, `ui_code` (`manifest.ex:986-997`);
- the document respects the existing render bounds: at most 24 widgets, 64
  fields, 8 table columns, 50 table rows, and 240 characters per rendered value.

An unknown key anywhere in the contract document SHALL be an import error, not a
silently ignored value.

#### Scenario: Unknown contract version rejected at import

- **GIVEN** a package whose `signal_schemas[].display_contract_version` declares
  a major version this web-ng release does not implement
- **WHEN** the package version is imported
- **THEN** the import SHALL fail with an error naming the offending schema entry
  and the supported contract versions
- **AND** no display contract SHALL be persisted for that package version

#### Scenario: Unsafe key rejected at import

- **GIVEN** a display contract document containing a `component_ref` or `html`
  key at any level
- **WHEN** the package version is imported
- **THEN** the import SHALL fail with an error stating that packages may not
  ship provider-owned UI code
- **AND** the message SHALL name the offending key and its path

#### Scenario: Unknown key rejected rather than ignored

- **GIVEN** a display contract widget carrying a key outside the documented
  allowlist
- **WHEN** the package version is imported
- **THEN** the import SHALL fail with a field-level error naming the key
- **AND** the package version SHALL NOT be persisted with the key stripped

#### Scenario: Bounds violation rejected at import

- **GIVEN** a display contract declaring more than 24 widgets or a table with
  more than 8 columns
- **WHEN** the package version is imported
- **THEN** the import SHALL fail with an error naming the exceeded bound

### Requirement: Notification provider configuration forms render from the package config schema

The notification channel editor under `/settings/notifications` SHALL render a
provider's configuration form from `NotificationProvider.config_schema` using
the existing constrained JSON Schema subset validated by
`ServiceRadar.Plugins.ConfigSchema` and rendered by
`ServiceRadarWebNGWeb.PluginConfigForm`
(`elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_config_form.ex:1`;
the module lives in the `components/` directory but is **not** namespaced under
`ServiceRadarWebNGWeb.Components`). It SHALL NOT introduce a second schema
subset, a second validator, or a provider-specific form module.

The form SHALL support the subset already implemented: property types
`string`, `integer`, `number`, `boolean`, `array`, `object`; formats `uri`,
`email`, and `password`; `title`, `description`, `default`, `enum`, and
`required`; plus the `secretRef` and `credentialKind` property keys.

Submitted channel configuration SHALL be validated against the provider's
`config_schema` in the Ash layer before `NotificationChannel.config` is
persisted, and violations SHALL be returned as field-level errors on the
offending property rather than a single opaque form error.

#### Scenario: Provider form generated from schema

- **GIVEN** a notification provider whose `config_schema` declares a required
  `webhook_url` of type `string` with format `uri` and an optional `username`
  of type `string`
- **WHEN** an operator creates a channel for that provider
- **THEN** the form SHALL render a required URL input and an optional text
  input, labelled from the schema `title` and `description`
- **AND** no provider-specific LiveView or component SHALL be required

#### Scenario: Invalid channel configuration rejected with field-level errors

- **WHEN** an operator submits channel configuration that violates the
  provider's `config_schema`
- **THEN** the save SHALL be rejected
- **AND** the error SHALL be attached to the specific offending property

#### Scenario: Declarative and plugin providers use the same renderer

- **GIVEN** one provider with `provider_type: :declarative` and one with
  `provider_type: :wasm_plugin`, each carrying a `config_schema`
- **WHEN** an operator configures a channel for each
- **THEN** both forms SHALL be produced by the same schema-driven renderer
- **AND** the rendered form SHALL NOT expose the provider tier as a difference
  in field behaviour

#### Scenario: Outbound URL fields are policy-checked on save

- **GIVEN** a `config_schema` property of type `string` with format `uri` that
  supplies an operator-controlled outbound destination
- **WHEN** the channel is saved
- **THEN** the value SHALL be validated by
  `Palisade.OutboundURLPolicy.validate_https_public_url/2`
- **AND** a rejected URL SHALL surface as a field-level error on that property

### Requirement: Notification secret fields never echo stored values

A `config_schema` property marked `secretRef: true` SHALL be rendered as a
secret reference control, and the stored secret value SHALL never be sent to the
browser, returned by an API response, or written into a LiveView assign.

The control SHALL render as a password-type input or a credential selector,
SHALL display only a set/unset indicator plus non-secret metadata for an
already-configured value, and SHALL leave the stored value unchanged when the
operator saves the form without re-entering it. Values SHALL be persisted as
`NotificationChannel.secret_refs` via `ServiceRadar.Plugins.SecretRefs` and
resolved at dispatch through `Credentials.SecretBroker`, never inlined into
`NotificationChannel.config`.

When a property additionally declares `credentialKind`, the credential selector
SHALL filter the offered reusable credentials to that kind, drawn from the
allowed set `api_token`, `username_password`, `ssh_private_key`, `certificate`,
`snmp`, `opaque`. An absent `credentialKind` SHALL mean unfiltered, preserving
the behaviour of packages already shipping `secretRef` without the hint.

#### Scenario: Configured secret is not echoed

- **GIVEN** a notification channel whose provider `config_schema` marks
  `api_token` as `secretRef: true` and the channel already has a stored value
- **WHEN** an operator reopens the channel editor
- **THEN** the field SHALL indicate that a secret is configured
- **AND** the stored secret value SHALL NOT appear in the rendered HTML, the
  socket assigns, or any API response

#### Scenario: Saving without re-entry preserves the secret

- **WHEN** an operator edits an unrelated field and saves the channel without
  re-entering the secret
- **THEN** the existing secret reference SHALL be preserved unchanged

#### Scenario: Credential kind narrows the selector

- **GIVEN** a `secretRef: true` property declaring `credentialKind:
  "username_password"`
- **WHEN** the operator opens the credential selector for that field
- **THEN** only reusable credentials of kind `username_password` SHALL be
  offered

#### Scenario: Secret never crosses the plugin boundary in config

- **GIVEN** a channel with `execution_route: :edge_agent` backed by a
  `:wasm_plugin` provider
- **WHEN** the channel configuration is delivered to the agent
- **THEN** the resolved secret SHALL NOT appear in `NotificationChannel.config`
  or in guest-visible parameters
- **AND** it SHALL be delivered through host-side credential injection or the
  trusted-host-only host parameter path

### Requirement: Provider-supplied contracts are declarative descriptions only

A display contract or `config_schema` shipped by a package SHALL describe
fields, field groups, ordering, labels, help text, units, and validation
constraints only. It SHALL NOT carry markup, templates, scripts, component
references, style sheets, or any other executable or renderable code, and the
web UI SHALL NOT evaluate contract content as markup.

Grouping and ordering SHALL be expressed as declarative data: an optional
ordered list of groups, each with a stable key, a title, an optional
description, and an ordered list of property names. Properties absent from every
group SHALL render in a default group in schema declaration order. A group
referencing an unknown property SHALL be an import-time error.

Rendered strings originating from a contract SHALL be escaped as text, SHALL
never be passed to `raw/1`, and SHALL be truncated to the documented per-value
bound.

#### Scenario: Contract cannot inject markup

- **GIVEN** a display contract whose field label or help text contains HTML tags
- **WHEN** the contract is rendered
- **THEN** the tags SHALL be escaped and displayed as literal text
- **AND** no markup from the contract SHALL be interpreted by the browser

#### Scenario: Groups and ordering are honoured

- **GIVEN** a `config_schema` declaring two groups with explicit property
  ordering
- **WHEN** the configuration form renders
- **THEN** fields SHALL appear in the declared groups and declared order
- **AND** properties omitted from all groups SHALL render in a default group in
  schema order

#### Scenario: Group referencing an unknown property is rejected

- **GIVEN** a group listing a property name that the schema does not declare
- **WHEN** the package version is imported
- **THEN** the import SHALL fail with an error naming the group and the unknown
  property

### Requirement: Display and config contract failures degrade gracefully

A missing, malformed, or partially unsupported contract SHALL NOT fail the page.
The UI SHALL render a safe generic view and surface a diagnostic naming the
package version and the specific problem.

Degradation rules:

- **No contract resolved.** Render the existing generic key/value view of the
  record or configuration, plus an informational notice that the package ships
  no display contract. This SHALL NOT be reported as an error.
- **Contract resolved but malformed at render time.** Render the generic view
  and surface a warning diagnostic. The LiveView SHALL NOT crash and SHALL NOT
  return a 500.
- **Unknown widget type.** Skip only the unsupported widget, render the
  remaining supported widgets, and surface a diagnostic naming the unknown type.
  A contract whose widgets are all unsupported SHALL fall back to the generic
  view rather than rendering an empty panel. This changes today's behaviour in
  `SignalDisplay.render/2`, where an unrecognised widget contributes nothing and
  a fully unrecognised contract collapses to `:error` with no operator-visible
  explanation.
- **Unknown field path.** Omit that field and record a diagnostic; do not fail
  the widget.
- **Value exceeding bounds.** Truncate to the documented per-value bound and
  mark the value as truncated.

Diagnostics SHALL be rate-limited so that a malformed contract on a
high-cardinality record stream cannot flood the log.

#### Scenario: Missing contract renders the generic view

- **WHEN** a record's producer identity resolves to no display contract
- **THEN** the generic key/value view SHALL render
- **AND** an informational notice SHALL state that the package ships no display
  contract

#### Scenario: Unknown widget type does not break the page

- **GIVEN** a contract with three widgets, one of an unrecognised `type`
- **WHEN** the record is rendered
- **THEN** the two supported widgets SHALL render
- **AND** a diagnostic naming the unknown widget type SHALL be surfaced
- **AND** the page SHALL return successfully

#### Scenario: Fully unsupported contract falls back rather than blanking

- **GIVEN** a contract in which no widget type is supported
- **WHEN** the record is rendered
- **THEN** the generic key/value view SHALL render
- **AND** a warning diagnostic SHALL name the package version and the
  unsupported types

#### Scenario: Malformed contract does not crash the LiveView

- **GIVEN** a persisted contract whose `widgets` value is not a list
- **WHEN** an operator opens a record for that package
- **THEN** the page SHALL render the generic view with a warning
- **AND** the LiveView SHALL NOT crash

#### Scenario: Diagnostics are rate-limited

- **GIVEN** a malformed contract for a package emitting a high volume of records
- **WHEN** many such records are rendered
- **THEN** the diagnostic SHALL be emitted at a bounded rate per package version
  rather than once per record

### Requirement: Contract diagnostics are enumerable for operators

Contract resolution and validation diagnostics SHALL be enumerable in the UI
against the package version that produced them, so an operator can answer "why
does this package render as raw key/value?" without reading server logs.

Each diagnostic SHALL record the package version identity, the producer and
schema identity from the record, a machine-readable reason
(`:no_contract`, `:unresolved_schema_ref`, `:malformed_contract`,
`:unsupported_widget`, `:unknown_field_path`, `:bounds_exceeded`,
`:unsupported_contract_version`), a human-readable message, and the timestamp
last observed. Diagnostics SHALL be deduplicated by
`{package_version, reason, detail}` with an occurrence count rather than stored
per record.

#### Scenario: Package detail page lists contract diagnostics

- **GIVEN** a package version whose contract references an unknown widget type
- **WHEN** an operator opens that package version in the plugin configuration UI
- **THEN** the page SHALL list the diagnostic with its reason, message, and
  occurrence count

#### Scenario: Healthy package shows no diagnostics

- **GIVEN** a package version whose contract resolves and renders cleanly
- **WHEN** an operator opens that package version
- **THEN** no contract diagnostics SHALL be listed

### Requirement: Notification delivery log rendering is contract-driven

The Delivery Log under `/settings/notifications` SHALL render provider-specific
delivery detail through the same package-shipped display contract mechanism used
for events and logs, and SHALL NOT require a provider-specific view module.

The generic, provider-neutral columns of a `NotificationDelivery` row SHALL
always render regardless of contract availability: `state` (`:pending`,
`:dispatching`, `:sent`, `:failed`, `:expired`, `:cancelled`, `:suppressed`,
`:skipped`), `suppression_reason`, `attempt_count`, `next_attempt_at`,
`error_class`, `error_message`, `channel_id`, `route_id`, `step_number`,
`execution_route`, `queued_at`, `started_at`, `finished_at`, `payload_format`,
`provider_version`, `originating_delivery_id`, and `is_test`. A provider
display contract MAY add a provider-specific detail panel - for example a Slack
message permalink derived from `external_correlation_id`, or a PagerDuty
deduplication key - but SHALL NOT remove, rename, or override a generic column.

Suppressed rows SHALL be displayed in the Delivery Log with their
`suppression_reason` rather than omitted, so that "why was I not paged?" is
answerable from this page alone. A row whose `is_test` is true SHALL be visually
distinguished from a real delivery.

Every value rendered from `result_summary`, `error_message`, or a contract-named
field SHALL pass `ActionRedaction` policy `northbound-action-redaction-v1`
before display, and `rendered_payload_digest` SHALL be shown in place of the
rendered payload itself.

#### Scenario: Provider detail panel from a package contract

- **GIVEN** a notification provider supplied by an uploaded package that ships a
  delivery display contract
- **WHEN** an operator opens a delivery row for a channel using that provider
- **THEN** the provider-specific panel SHALL render from the package contract
- **AND** no provider-specific view module SHALL be required in web-ng

#### Scenario: Generic columns survive a missing contract

- **GIVEN** a provider that ships no delivery display contract
- **WHEN** an operator opens a delivery row for that provider
- **THEN** the generic delivery columns including `state`,
  `suppression_reason`, `attempt_count`, and `error_class` SHALL render
- **AND** only the provider-specific panel SHALL be absent

#### Scenario: Suppressed rows are listed, not hidden

- **GIVEN** a delivery row with `state: :suppressed` and a `suppression_reason`
- **WHEN** an operator opens the Delivery Log
- **THEN** the row SHALL be listed with its `suppression_reason` rendered
- **AND** it SHALL NOT be omitted from the log

#### Scenario: Test deliveries are visually distinguished

- **GIVEN** a delivery row whose `is_test` is true
- **WHEN** an operator opens the Delivery Log
- **THEN** the row SHALL be visually distinguished from a real delivery

#### Scenario: Contract cannot override a generic column

- **GIVEN** a delivery display contract declaring a widget bound to the reserved
  `state` column
- **WHEN** the package version is imported
- **THEN** the import SHALL fail with an error naming the reserved column

#### Scenario: Delivery detail is redacted before display

- **WHEN** a delivery row's `result_summary` or `error_message` is rendered
- **THEN** the value SHALL pass `ActionRedaction` policy
  `northbound-action-redaction-v1` before it reaches the browser
- **AND** the rendered payload SHALL be represented by
  `rendered_payload_digest`, not by its contents

### Requirement: Notification channel health rendering is contract-driven

Channel health detail SHALL be rendered through the same package-shipped display
contract mechanism, with a provider-neutral floor that always renders.

The floor SHALL comprise `NotificationChannel.health`, `last_success_at`,
`last_failure_at`, `last_error`, `enabled`, `execution_route`, and, when
`execution_route` is `:edge_agent`, `agent_uid` and the resolved agent
reachability state. A provider MAY contribute additional health facts through
its display contract - for example a remaining rate-limit budget or a
provider-reported quota - subject to the same declarative-only, bounds-checked,
escaped rendering rules as every other contract.

Channel health rendering SHALL NOT depend on a live call to the provider; it
SHALL render from persisted channel state so that an unreachable provider or an
offline agent cannot block the page.

#### Scenario: Provider health facts from a package contract

- **GIVEN** a provider whose package ships a channel health display contract
- **WHEN** an operator opens the channel detail page
- **THEN** the provider health facts SHALL render from the contract alongside
  the provider-neutral floor

#### Scenario: Health floor renders without a contract

- **GIVEN** a provider that ships no channel health display contract
- **WHEN** an operator opens the channel detail page
- **THEN** `health`, `last_success_at`, `last_failure_at`, and `last_error`
  SHALL render
- **AND** a diagnostic SHALL NOT be raised, because shipping no contract is not
  an error

#### Scenario: Offline edge agent does not block the page

- **GIVEN** a channel with `execution_route: :edge_agent` whose agent has no
  control session
- **WHEN** an operator opens the channel detail page
- **THEN** the page SHALL render from persisted channel state
- **AND** the agent reachability state SHALL be displayed as unreachable rather
  than the page failing or hanging on a live call
