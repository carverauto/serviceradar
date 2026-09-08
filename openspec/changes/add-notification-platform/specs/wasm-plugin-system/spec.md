## ADDED Requirements

### Requirement: Notification Provider Manifest Block

`plugin.yaml` SHALL support an optional top-level `notifications:` block that declares one or more notification providers shipped by the package. `ServiceRadar.Plugins.Manifest` SHALL parse and validate the block during package import and SHALL reject the package when any declared provider is malformed, exactly as it does for `actions`, `producer_schedules`, and `signal_schemas`.

Each entry in `notifications:` SHALL be composed of exactly the following ten keys and no others:

- `key` - the notification action key (for example `mattermost`, `opsgenie`); a non-empty string, unique within the package. A `NotificationProvider` with `provider_type: :wasm_plugin` bound to this package SHALL carry this value as its `action_key`.
- `display_name` - a non-empty human-readable string.
- `description` - a human-readable description of what the provider sends and where; optional, and when present it SHALL be a string.
- `entrypoint` - the exported Wasm function invoked to send a notification.
- `config_schema` - a bundle-relative path to a JSON Schema subset document validated by `ServiceRadar.Plugins.ConfigSchema`.
- `capabilities` - a subset of `send`, `test`, `resolve_update`, `inbound_callback`, `rich_payload`, `attachments`, `threading`, which SHALL contain both `send` and `test`.
- `payload_formats` - a subset of `slack_blocks`, `discord_embed`, `markdown`, `plain`, `html`, `pagerduty_v2`, `json`.
- `routes` - a non-empty subset of `control_plane`, `edge_agent`; it populates `NotificationProvider.supported_routes`.
- `credential_requirements` - a list of `{key, kind, inject}` entries where `inject` names one of the canonical host-supported injection modes enumerated in the credential-injection requirement below.
- `inbound` - a map of `{mode, verification}` where `mode` is one of `none`, `signed_action_link`, `provider_callback`.

Those ten keys are the complete recognized set, and the manifest validator owns them. Any other key inside a `notifications:` entry SHALL be a validation error rather than an ignored value. In particular `provider_key` and `inbound_callback` are NOT entry keys: the provider's action key is spelled `key`, and the inbound declaration is spelled `inbound` (`inbound_callback` exists only as a member of the `capabilities` allowlist).

Every enumerated field SHALL be validated against a fixed allowlist. Unknown members of `capabilities`, `payload_formats`, `routes`, or `inbound.mode` SHALL be a validation error, not a silently ignored value.

Every notification provider, in every tier, SHALL implement a test action. A `notifications:` entry whose `capabilities` omits `send`, omits `test`, or omits both SHALL be rejected by manifest validation, and the package SHALL NOT be stored as importable.

A `notifications:` entry SHALL NOT contain any credential value, secret, token, or password. `credential_requirements` declares only the shape of the credential the operator must supply.

#### Scenario: Well-formed notifications block is accepted

- **WHEN** a plugin package is imported whose `plugin.yaml` declares a `notifications:` entry with `key`, `display_name`, `description`, `entrypoint`, `config_schema`, `capabilities`, `payload_formats`, `routes`, `credential_requirements`, and `inbound`
- **THEN** `ServiceRadar.Plugins.Manifest` SHALL parse the entry into a normalized notification provider descriptor
- **AND** the descriptor SHALL be available to the control plane for creating a `NotificationProvider` with `provider_type: :wasm_plugin` whose `action_key` is the entry's `key`

#### Scenario: Unknown enumerated value is rejected

- **WHEN** a `notifications:` entry declares `payload_formats: [teams_adaptive_card]` or `routes: [site_agent]`
- **THEN** manifest validation SHALL fail with an error naming the offending field and value
- **AND** the package SHALL NOT be stored as importable

#### Scenario: Missing required provider field is rejected

- **WHEN** a `notifications:` entry omits `key`, `entrypoint`, `config_schema`, or `routes`
- **THEN** manifest validation SHALL fail with an error identifying the entry index and the missing field

#### Scenario: Unrecognized entry key is rejected

- **WHEN** a `notifications:` entry declares a key outside the recognized set, such as `provider_key:` in place of `key:` or a top-level `inbound_callback:` in place of `inbound:`
- **THEN** manifest validation SHALL fail with an error naming the unrecognized key and listing the ten recognized keys
- **AND** the package SHALL NOT be stored as importable

#### Scenario: Capabilities without send and test is rejected

- **WHEN** a `notifications:` entry declares `capabilities: [send, rich_payload]`, or `capabilities: [test]`, or any `capabilities` list missing `send` or `test`
- **THEN** manifest validation SHALL fail with an error stating that every notification provider must declare both `send` and `test`
- **AND** the package SHALL NOT be stored as importable

#### Scenario: Duplicate provider key within one package is rejected

- **WHEN** two `notifications:` entries in the same `plugin.yaml` declare the same `key`
- **THEN** manifest validation SHALL fail
- **AND** neither provider SHALL be registered

#### Scenario: Embedded secret material is rejected

- **WHEN** a `notifications:` entry supplies a literal token, password, or API key inside `credential_requirements` or the entry body
- **THEN** manifest validation SHALL fail
- **AND** the error SHALL state that credential values are supplied by the operator through `Credentials.SecretBroker`, never by the manifest

### Requirement: Notification Providers Ship No UI Markup

A `notifications:` manifest entry SHALL be subject to the same provider-supplied-UI prohibition already enforced on action descriptors. `ServiceRadar.Plugins.Manifest` SHALL reject a notification provider entry that contains any of the keys `html`, `raw_html`, `javascript`, `js`, `component`, `component_ref`, `live_view`, `react`, or `ui_code`, matching the existing rejection at `elixir/serviceradar_core/lib/serviceradar/plugins/manifest.ex:986-997`.

A notification provider SHALL describe its configuration surface only through its declared `config_schema` JSON Schema document and its declarative display contract. Rendering SHALL remain owned by ServiceRadar. A provider SHALL NOT ship markup, templates that are evaluated as code, or client-side script.

Notification body and subject templates supplied by a plugin package SHALL use only the restricted substitution engine (whitelisted variable paths plus the fixed filter set `upper`, `lower`, `truncate`, `json`, `url_encode`, `iso8601`, `default`). EEx, arbitrary code evaluation, and `raw/1` over provider-supplied content SHALL be prohibited.

#### Scenario: Provider entry carrying markup is rejected

- **WHEN** a `notifications:` entry declares a `component_ref` or an `html` key
- **THEN** manifest validation SHALL fail with an error stating that notification providers may not ship provider-owned UI code
- **AND** the package import SHALL be rejected

#### Scenario: Declarative config schema is accepted

- **WHEN** a `notifications:` entry declares only `config_schema` pointing at a bundle-relative JSON Schema document
- **THEN** validation SHALL succeed
- **AND** the control plane SHALL render the provider configuration form from that schema

#### Scenario: Template containing code is rejected

- **WHEN** a package-supplied notification template contains an EEx expression or any construct outside the whitelisted variable paths and fixed filter set
- **THEN** template validation SHALL fail
- **AND** the provider SHALL NOT become `:active`

### Requirement: Notify Capability Is Allowlisted In Elixir And Enforced In The Agent

The capability string `notify:v1` SHALL be added to `@allowed_capabilities` in `elixir/serviceradar_core/lib/serviceradar/plugins/manifest.ex:61-83`, **and** SHALL be enforced at runtime by a `hasCapability("notify:v1")` check in `go/pkg/agent` on every host function and dispatch path that performs notification delivery on behalf of a plugin.

Declaring the capability in the Elixir allowlist alone SHALL NOT be considered implementing this requirement. `advisory-feed:v1` and `producer-schedule:v1` are present in `@allowed_capabilities` today with no corresponding `hasCapability` check anywhere in `go/pkg/agent`; those are declared-but-unenforced defects and this change SHALL NOT add a third. The agent-side enforcement SHALL follow the existing pattern used for `artifact-staging:v1` (`go/pkg/agent/plugin_runtime_artifact.go:97,128,164,224`) and `camera_media_stream` (`go/pkg/agent/plugin_runtime_execution.go:284,305,337,357`), returning the standard plugin error code on denial rather than failing open.

Enforcement SHALL be evaluated against the plugin's **effective** capability set delivered in the agent configuration, not against the raw manifest.

#### Scenario: Plugin without notify:v1 is denied at the agent

- **GIVEN** a Wasm plugin whose effective capability set does not include `notify:v1`
- **WHEN** the plugin invokes a notification host function or the agent receives a notification action dispatch for that plugin
- **THEN** the agent SHALL deny the call
- **AND** SHALL return a capability-denied plugin error code
- **AND** SHALL NOT perform any outbound delivery

#### Scenario: Plugin with notify:v1 is permitted

- **GIVEN** a Wasm plugin whose effective capability set includes `notify:v1`
- **WHEN** the plugin performs a notification send through the declared entrypoint
- **THEN** the agent SHALL permit the call
- **AND** SHALL apply the remaining per-call permission and allowlist checks unchanged

#### Scenario: Elixir-only declaration is not sufficient

- **GIVEN** `notify:v1` present in `@allowed_capabilities` in `manifest.ex`
- **AND** no `hasCapability("notify:v1")` check present in `go/pkg/agent`
- **WHEN** the enforcement test suite runs
- **THEN** the suite SHALL fail
- **AND** the capability SHALL NOT be considered shipped

#### Scenario: Capability removed at approval is denied at runtime

- **GIVEN** a package that requested `notify:v1` but had it removed during staged import review
- **WHEN** the agent receives configuration for an assignment of that package
- **THEN** `notify:v1` SHALL be absent from the delivered effective capabilities
- **AND** any notification host call from that plugin SHALL be denied

### Requirement: Notification Action Dispatch Uses The Existing plugin.run_action Path

Notification delivery through a `:wasm_plugin` provider SHALL be dispatched using the existing `plugin.run_action` command type over `ServiceRadar.Edge.AgentCommandBus`, identically for the `:control_plane` route (targeting the platform-resident `serviceradar-agent`) and the `:edge_agent` route (targeting a named site agent). No second command type, transport, or dispatch path SHALL be introduced for notifications.

The command payload SHALL identify the plugin package, the notification provider `key`, the provider `entrypoint`, and the rendered payload. The payload SHALL carry no secret material; see the credential-injection requirement below.

The agent command result SHALL be treated as a wake-up signal only. The `NotificationDelivery` row in the control plane SHALL remain the system of record for delivery outcome, mirroring the coordinator pattern documented at `elixir/serviceradar_core/lib/serviceradar/automation/ansible/callback_command_result_coordinator.ex:1-10`.

#### Scenario: Control-plane plugin channel dispatches through plugin.run_action

- **GIVEN** a `NotificationChannel` whose provider is `:wasm_plugin` and whose `execution_route` is `:control_plane`
- **WHEN** the delivery worker dispatches the notification
- **THEN** the dispatch SHALL be a `plugin.run_action` command addressed to the platform-resident agent
- **AND** the same command shape SHALL be used as for an `:edge_agent` dispatch of the same provider

#### Scenario: Agent offline yields a recorded delivery outcome

- **GIVEN** an `:edge_agent` channel whose target agent has no control session
- **WHEN** `AgentCommandBus.dispatch/4` returns `{:error, {:agent_offline, agent_id}}`
- **THEN** the `NotificationDelivery` row SHALL record the failure with an `error_class` identifying the offline agent
- **AND** the delivery SHALL fail over to `fallback_channel_id` unless the channel is `fail_closed`

#### Scenario: Command result never overrides the delivery row

- **GIVEN** a dispatched notification whose agent command result is lost or arrives late
- **WHEN** the reconciler scans due deliveries
- **THEN** the `NotificationDelivery` row SHALL determine the delivery state
- **AND** the missing command result SHALL NOT leave the delivery in an indeterminate state

### Requirement: Notification Plugin Assignments Use The Existing Capability Narrowing Funnel

What reaches the agent for a notification-capable plugin SHALL be the narrowed `effective_capabilities`, `effective_permissions`, and `effective_resources` computed by `ServiceRadar.Edge.AgentConfigGenerator` (`elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex:1848-1877`): manifest request, narrowed by package approval, narrowed again by assignment override.

A notification provider SHALL NOT bypass, widen, or short-circuit this funnel. In particular, the `notifications:` manifest block SHALL NOT grant any capability, permission, domain, network, or port that the approved package policy and the assignment override do not already allow. Where the two disagree, the narrower set SHALL win.

#### Scenario: Assignment override narrows a notification plugin

- **GIVEN** a package approved with `http_request` allowlisting `hooks.example.com` and `notify:v1`
- **AND** an assignment override that removes `notify:v1`
- **WHEN** the agent configuration is generated
- **THEN** the delivered effective capabilities SHALL exclude `notify:v1`
- **AND** notification dispatch to that assignment SHALL be denied at the agent

#### Scenario: Manifest cannot widen approved allowlists

- **GIVEN** a `notifications:` entry whose provider implies egress to an additional domain
- **AND** a package approval whose allowlist does not include that domain
- **WHEN** the plugin issues an outbound request to it
- **THEN** the agent SHALL deny the request
- **AND** the denial SHALL be recorded on the delivery record

### Requirement: Notification Providers Bind Only To Approved Plugin Packages

A `NotificationProvider` with `provider_type: :wasm_plugin` SHALL reference a `plugin_package_id` that has passed staged import review, and its `action_key` SHALL equal the `key` of exactly one entry in the `notifications:` block of that package's validated manifest. That equality is the definition of `action_key` for notification providers: `NotificationProvider.action_key == notifications[].key`. Creating or activating such a provider against an unapproved, denied, or missing package SHALL be rejected, as SHALL an `action_key` that matches no entry.

Revoking or denying the underlying package SHALL disable every `NotificationProvider` and `NotificationChannel` bound to it, and subsequent dispatch attempts SHALL produce a `NotificationDelivery` row with `state: :suppressed` and `suppression_reason: :channel_disabled` rather than a silent drop.

#### Scenario: Provider on an unapproved package cannot activate

- **WHEN** an operator attempts to move a `:wasm_plugin` `NotificationProvider` to `:active` while its package is staged but not approved
- **THEN** the transition SHALL be rejected with an error naming the package approval state

#### Scenario: action_key must equal a manifest notifications key

- **WHEN** a `NotificationProvider` declares an `action_key` that does not equal the `key` of any entry in the package's validated `notifications:` block
- **THEN** creation SHALL be rejected
- **AND** the error SHALL list the `key` values the package's `notifications:` block does declare

#### Scenario: Package denial disables bound channels auditably

- **GIVEN** an active channel backed by a `:wasm_plugin` provider
- **WHEN** the underlying package is denied or revoked
- **THEN** the provider and its channels SHALL be disabled
- **AND** any routed notification SHALL produce a delivery row with `state: :suppressed` and `suppression_reason: :channel_disabled`

### Requirement: Host-Side Credential Injection For Notification Providers

Credentials used by a notification plugin SHALL be injected by the host at request construction time. Secret material SHALL NOT enter Wasm guest memory and SHALL NOT appear in `params_json`, in the plugin's configuration document, in any log line, or in any persisted delivery record.

The supported injection modes SHALL be exactly the six canonical modes the agent host already implements: `http_header`, `bearer_token`, `basic_auth`, `query`, and `form_urlencoded` in `applyCredentialBrokerHTTPInjection` (`go/pkg/agent/plugin_runtime_actions.go:308-356`), plus `oauth2_password_bearer`, which is dispatched ahead of that function at `go/pkg/agent/plugin_runtime_http.go:398`. Those six spellings are canonical everywhere in this change: in the manifest, in the SDK, in the control-plane resources, and in operator-facing documentation.

A `credential_requirements` entry SHALL name its injection mode using the canonical spelling. `bearer`, `basic`, `header`, and `form` are NOT canonical names and SHALL NOT appear in a manifest; neither SHALL the legacy aliases the Go switch still tolerates for backwards compatibility (`header`, `http_basic_auth`, `query_param`, `http_query`). A `notifications:` entry whose `credential_requirements` names an alias, or any mode outside the canonical set, SHALL be rejected by manifest validation.

Credential resolution SHALL go through `ServiceRadar.Credentials.SecretBroker` and a `CredentialBrokerGrant`, never through `Vault.decrypt!` directly. Where a trusted-host-only value must reach the agent, it SHALL travel in the proto field `host_params_json` (`proto/monitoring.proto:615-623`) and SHALL NOT be echoed into guest-visible parameters.

Because no supported injection mode rewrites a URL path, a provider whose secret lives in the URL path (Slack and Discord incoming-webhook URLs) SHALL either use a token-based API with `bearer_token` or carry the URL through `host_params_json`. Adding a URL-path injection mode is out of scope and SHALL NOT be introduced by this change.

#### Scenario: Bearer token is injected without entering guest memory

- **GIVEN** a notification provider declaring `credential_requirements` with `inject: bearer_token`
- **WHEN** the plugin issues its outbound request through the host
- **THEN** the host SHALL resolve the credential through `SecretBroker` and set the `Authorization` header on the outgoing request
- **AND** the guest SHALL never observe the credential value
- **AND** the value SHALL be absent from `params_json`, logs, and the persisted delivery record

#### Scenario: Unsupported injection mode is rejected at import

- **WHEN** a `notifications:` entry declares `inject: url_path`
- **THEN** manifest validation SHALL fail with an error naming the six canonical injection modes `http_header`, `bearer_token`, `basic_auth`, `query`, `form_urlencoded`, and `oauth2_password_bearer`
- **AND** the package SHALL NOT be importable

#### Scenario: Non-canonical injection alias is rejected at import

- **WHEN** a `notifications:` entry declares `inject: bearer`, `inject: basic`, `inject: header`, `inject: form`, or a legacy alias such as `inject: query_param`
- **THEN** manifest validation SHALL fail with an error naming the canonical spelling to use instead
- **AND** the package SHALL NOT be importable

#### Scenario: Credential material never reaches the delivery record

- **GIVEN** a notification delivered through a plugin using `basic_auth` injection
- **WHEN** the `NotificationDelivery` row and its `result_summary` are written
- **THEN** the persisted content SHALL have passed `ActionRedaction` under policy `northbound-action-redaction-v1`
- **AND** SHALL contain no credential value

#### Scenario: Missing credential fails the delivery rather than sending unauthenticated

- **GIVEN** a grant whose credential material cannot be resolved
- **WHEN** the host attempts injection
- **THEN** the request SHALL NOT be sent
- **AND** the delivery SHALL be recorded as failed with an `error_class` identifying unavailable credential material

### Requirement: Notification Plugin Egress Uses The Single Hardened Host HTTP Boundary

All outbound network egress performed by a notification plugin SHALL traverse the existing hardened `hostHTTPRequest` boundary in `go/pkg/agent/plugin_runtime_http.go`. No second egress path, relaxed HTTP client, or notification-specific bypass SHALL be introduced.

That boundary SHALL continue to apply, unchanged, to notification traffic:

- the `http_request` capability check (`plugin_runtime_http.go:72`), in addition to the `notify:v1` check;
- the approved domain, network, and port allowlists;
- the response body size cap;
- the redirect bound and the re-validation of every redirect hop against the same allowlist and, for credential-bearing requests, against the grant's method, path, and port, so a same-host redirect cannot bypass the grant.

A notification plugin that requires a non-HTTP transport SHALL use the existing declared host functions for that transport under their existing capability gates; it SHALL NOT open sockets directly.

#### Scenario: Notification egress to a non-allowlisted host is denied

- **GIVEN** a notification plugin with `notify:v1` and `http_request`
- **WHEN** it attempts delivery to a host outside the approved allowlist
- **THEN** the agent SHALL deny the request
- **AND** the delivery SHALL be recorded as failed with an allowlist-denied `error_class`

#### Scenario: Redirect off the allowlist is re-validated and denied

- **GIVEN** an allowlisted notification endpoint that responds with a redirect to a non-allowlisted host
- **WHEN** the host follows the redirect
- **THEN** the redirect target SHALL be re-validated against the allowlist
- **AND** the request SHALL be denied rather than followed

#### Scenario: Oversized provider response is capped

- **GIVEN** a notification endpoint returning a response body larger than the configured cap
- **WHEN** the host reads the response
- **THEN** the read SHALL be bounded by the cap
- **AND** the plugin SHALL receive a bounded-response error rather than unbounded memory growth

#### Scenario: No parallel egress client is introduced

- **WHEN** the notification plugin implementation is reviewed
- **THEN** there SHALL be exactly one HTTP egress implementation available to plugins in `go/pkg/agent`
- **AND** notification delivery SHALL call it rather than constructing its own client

### Requirement: Exactly One Wasm Host Runtime Serves Notification Providers

The product SHALL contain exactly one Wasm host runtime for plugins: the wazero host in `go/pkg/agent`, whose guest ABI is the set of host functions exported into module `env` (`go/pkg/agent/plugin_runtime_execution.go:94-177`) together with the ptr/len guest-memory convention and the `pluginErr*` return codes.

A notification provider SHALL NOT introduce, require, or justify a second Wasm host. Specifically, no Rustler/wasmtime NIF, no server-side embedded runtime in `serviceradar_core` or `web-ng`, and no separate Go sidecar host SHALL be added to execute notification plugins centrally. Central execution SHALL be achieved by dispatching to the platform-resident `serviceradar-agent` over the same `plugin.run_action` path.

A plugin authored for the edge SHALL run unchanged on the platform agent, because it is the same binary in the same runtime. Relocating a channel between `:control_plane` and `:edge_agent` SHALL be a data edit plus a `PluginAssignment`, never a repackage or a rebuild.

#### Scenario: The same bundle runs on both routes

- **GIVEN** a signed notification plugin bundle assigned to a site agent
- **WHEN** the channel's `execution_route` is changed to `:control_plane`
- **THEN** the same bundle SHALL execute on the platform-resident agent
- **AND** no repackaging, recompilation, or alternate artifact SHALL be required

#### Scenario: A second host runtime is rejected

- **WHEN** an implementation proposes executing notification plugins inside `serviceradar_core` or `web-ng` through an embedded Wasm runtime
- **THEN** the change SHALL be rejected as a duplicate host ABI implementation
- **AND** the control-plane dispatch to the platform agent SHALL be used instead

### Requirement: Notification Inbound Callback Verification Is Host-Owned

When a `notifications:` entry declares `inbound.mode` other than `none`, the inbound verification SHALL be performed by ServiceRadar, not by the plugin. The `inbound.verification` block SHALL declare only the scheme and the header or field names the host must read; it SHALL NOT supply a shared secret and SHALL NOT designate the guest as the verifier.

Verification SHALL reuse the existing northbound callback mechanisms: token supplied by header, Bearer, or body; sha256-only token persistence; `Edge.Crypto`-encrypted HMAC secret; comparison via `Plug.Crypto.secure_compare`; and HMAC-SHA256 over `<timestamp>.<raw_body>` with a 300 second tolerance. An inbound callback that fails verification SHALL be rejected before any alert state transition is attempted.

A plugin SHALL NOT be able to assert an acknowledgement, snooze, resolve, or suppress outcome that did not pass host verification.

#### Scenario: Declared inbound callback is verified by the host

- **GIVEN** a notification provider declaring `inbound: {mode: provider_callback, verification: {scheme: hmac_sha256, ...}}`
- **WHEN** an inbound callback arrives for a delivery from that provider
- **THEN** ServiceRadar SHALL verify the token and the HMAC over `<timestamp>.<raw_body>` within the 300 second tolerance
- **AND** SHALL create the `NotificationAcknowledgement` only when verification succeeds

#### Scenario: Manifest cannot supply the verification secret

- **WHEN** an `inbound.verification` block contains a literal secret or key value
- **THEN** manifest validation SHALL fail
- **AND** the package SHALL NOT be importable

#### Scenario: Failed verification does not transition the alert

- **GIVEN** an inbound callback whose HMAC does not match or whose timestamp is outside tolerance
- **WHEN** the callback is processed
- **THEN** it SHALL be rejected
- **AND** no `Alert` state transition and no `NotificationAcknowledgement` SHALL be recorded

### Requirement: Notification Plugin Bundle Files Are Registered In All Three Hand-Synced Places

Any file a first-party notification plugin bundle ships beyond the already-registered `plugin.yaml`, `plugin.wasm`, `config.schema.json`, and `display_contract.json` SHALL be registered in all three hand-synchronized locations before the bundle is published:

1. the bundle-entry allowlist in `elixir/web-ng/lib/serviceradar_web_ng/plugins/first_party_importer.ex` (the accepted-entry predicate around line 410, plus any per-entry size limit);
2. the required-entry set, per-entry size limits, and directory-prefix rules in `scripts/validate-external-wasm-plugin-bundle.py` (`REQUIRED_ENTRIES` and the `display/` / `schemas/` prefix rule);
3. the bundle file tuples for the plugin in `build/wasm_plugins/plugin_inventory.bzl`.

Registering a file in fewer than all three places SHALL be treated as an incomplete change. A file present in the Bazel bundle but absent from the importer allowlist SHALL be dropped at import; a file present in the bundle but absent from the validator rules SHALL fail publication verification.

#### Scenario: Unregistered bundle file is dropped at import

- **GIVEN** a notification plugin bundle shipping a new sidecar file not present in the `first_party_importer.ex` allowlist
- **WHEN** the bundle is imported
- **THEN** the file SHALL NOT be accepted into the package
- **AND** any provider behavior depending on it SHALL be unavailable

#### Scenario: Unregistered bundle file fails publication verification

- **GIVEN** a notification plugin bundle shipping a file not permitted by `scripts/validate-external-wasm-plugin-bundle.py`
- **WHEN** the publication verification workflow runs
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be treated as successfully published

#### Scenario: All three registrations present

- **GIVEN** a new notification sidecar registered in `first_party_importer.ex`, `validate-external-wasm-plugin-bundle.py`, and `plugin_inventory.bzl`
- **WHEN** the bundle is built, published, verified, and imported
- **THEN** every stage SHALL accept the file
- **AND** the file SHALL be available to the notification provider descriptor
