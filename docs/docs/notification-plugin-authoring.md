---
title: Notification Plugins (Wasm)
---

# Authoring a Wasm Notification Plugin

The [declarative tier](./notification-providers.md) covers roughly 85% of every
notification destination in existence, because most of them are one sentence:
POST this JSON body to this URL with these headers. This page is about the other
15% - the destinations that need a signature computed, an OAuth exchange, a
non-HTTP transport, a payload no template can express, or egress from inside a
customer network.

Those are `wasm_plugin` providers. A package declares its notifiers in a
`notifications:` block in `plugin.yaml`, the platform validates that block at
import, and the agent's Wasm host runs the module when a delivery is dispatched
to it.

This page is the authoring reference for the contract between the two. To
page Discord or Slack for the first time, see the
[Notifications Quickstart](./notification-quickstart.md). For channels, routes,
escalation, and the Delivery Log, see
[How Notifications Work](./notifications.md). For the no-code tier, see
[Declarative Providers](./notification-providers.md). For the plugin sandbox
itself - capabilities, permissions, signing, and the import workflow - see
[Wasm Plugins](./wasm-plugins.md).

## Before you start

- Use an SDK. `serviceradar-sdk-go` and `serviceradar-sdk-rust` both ship the
  notifier envelopes, the manifest-block builder, and the credential helpers,
  and both emit exactly the keys the platform validator accepts. See
  [SDKs & Plugin Development](./sdks.md). When fetching the Go SDK, set
  `GOPRIVATE=github.com/carverauto/serviceradar-sdk-go` — the module is not
  served via the public Go proxy, so Go must resolve it directly from GitHub.
- A notifier package is an ordinary signed Wasm plugin package. It is uploaded,
  approved, and assigned like any other, and it delivers nothing until it is
  **approved with `notify:v1`** and **assigned to an agent**.
- Read [What this tier is, and where it stops](#what-this-tier-is-and-where-it-stops)
  first. Writing a Wasm plugin for a destination the declarative tier already
  covers costs you a toolchain, a release cycle, and a signature for no
  behaviour the platform did not already have.

## What this tier is, and where it stops

| You want | Tier |
| --- | --- |
| POST/PUT/PATCH a rendered body to a URL | [Declarative](./notification-providers.md) |
| Request signing, an OAuth exchange, a second request, value mapping | `wasm_plugin`. This page |
| Message threading, attachments, a resolve-update request, an inbound callback | `wasm_plugin` |
| A payload the seven-filter template language cannot express | `wasm_plugin` |
| Egress from inside a customer network | `wasm_plugin` on the `edge_agent` route |
| A destination ServiceRadar already ships | Nothing. Configure a channel |

There are exactly three extensibility tiers - `native`, `declarative`, and
`wasm_plugin` - plus a built-in `stream` provider type that operators cannot
author. Nothing in this repository ships a first-party notifier bundle: every
destination we would ship ourselves is reachable from the platform and is "POST
this JSON to this URL", which is the declarative tier's job. The example notifier
and its fixture corpus live in the SDKs.

## The `notifications:` manifest block

A package that ships notifiers declares them in `plugin.yaml`. Each entry
describes exactly one notifier.

```yaml
id: acme-notifier
name: Acme Notifier
version: 1.0.0
entrypoint: run_action
runtime: wasi-preview1
outputs: serviceradar.plugin_result.v1
capabilities: [get_config, log, http_request, "notify:v1"]
permissions:
  allowed_domains: [api.acme.example]
  allowed_ports: [443]
resources:
  requested_memory_mb: 32
  requested_cpu_ms: 5000
notifications:
  - key: acme_incidents
    display_name: Acme Incidents
    description: Routes alerts to the Acme incident API
    entrypoint: notify_acme
    config_schema:
      type: object
      additionalProperties: false
      required: [base_url, api_token]
      properties:
        base_url:
          type: string
          title: API base URL
        api_token:
          type: string
          title: API token
          secretRef: true
          credentialKind: api_token
    capabilities: [send, test, resolve_update]
    payload_formats: [json]
    routes: [control_plane, edge_agent]
    credential_requirements:
      api_token:
        injection_mode: bearer_token
    inbound:
      enabled: false
```

### The ten keys

The key set is **closed**. These ten names are the whole contract, and anything
else is rejected by name and index rather than ignored.

| Key | Required | Default | What it is |
| --- | --- | --- | --- |
| `key` | yes | - | Slug naming this notifier inside the package. Lowercase letters, numbers, dots, underscores, hyphens. This is what a `NotificationProvider.action_key` binds to |
| `display_name` | yes | - | Human label shown when an operator picks a provider |
| `description` | no | omitted | One or two sentences of prose |
| `entrypoint` | yes | - | The exported guest function for this notifier. See [One export, many notifiers](#one-export-many-notifiers) before you rely on it |
| `config_schema` | no | empty | JSON Schema subset describing the channel configuration form. Validated by the same validator the declarative tier uses |
| `capabilities` | yes | - | What this notifier can do. Must include both `send` and `test` |
| `payload_formats` | yes | - | Rendered formats this notifier accepts. Must be non-empty |
| `routes` | no | `[control_plane]` | Execution routes this notifier supports |
| `credential_requirements` | no | empty | Named credentials and how the host injects them |
| `inbound` | no | disabled | Inbound callback configuration |

A misspelled key is a setting that quietly did nothing, so the validator refuses
the manifest at import instead of shipping a notifier whose credential
requirements or callback configuration silently vanished.

Two near-miss spellings were considered during design and are deliberately
**not** accepted, because both are plausible enough that an SDK could emit one
and produce a manifest the platform rejects:

| Not accepted | Spell it | Why |
| --- | --- | --- |
| `provider_key` | `key` | The entry key names the notifier inside the package. The *provider* key is chosen by the operator when the `NotificationProvider` row is created, and is not the package's to pick |
| `inbound_callback` | `inbound` | `inbound_callback` is the name of the **capability**. The block that configures it is `inbound` |

### capabilities

| Capability | Meaning |
| --- | --- |
| `send` | Deliver a notification. **Mandatory** |
| `test` | Deliver a test notification. **Mandatory** |
| `resolve_update` | Send a follow-up when the alert resolves |
| `inbound_callback` | Accept a signed callback from the destination |
| `rich_payload` | Render structured rather than plain content |
| `attachments` | Attach files |
| `threading` | Reply into an existing thread |

`send` and `test` are mandatory in every tier, so that "test-send before saving"
works uniformly and no provider can opt out of being testable. An entry missing
either is rejected and the error names which one.

`inbound_callback` and the `inbound` block are two halves of one decision, and
declaring either alone is refused: an enabled callback without the capability
would be unreachable, and the capability without an enabled callback grants
nothing.

### payload_formats and routes

`payload_formats` may name `slack_blocks`, `discord_embed`, `markdown`, `plain`,
`html`, `pagerduty_v2`, or `json`. An empty list is refused - a notifier that can
render nothing cannot deliver anything.

`routes` may name `control_plane` or `edge_agent`, and defaults to
`[control_plane]`, which is the documented recommendation. See
[The two execution routes](#the-two-execution-routes).

### config_schema

The channel configuration form is generated from this schema, and it is read
from the package's **current** manifest at render time rather than from a copy
taken when the provider row was created - so upgrading a package reaches the
form without an operator re-creating anything.

Mark a credential field `secretRef: true`. That is what makes the platform store
a reference rather than the value, classify the field as secret in the form, and
keep it out of the test-send payload. A field the schema does not mark as secret
is ordinary configuration everywhere in the system.

### credential_requirements

A map of credential name to a closed, typed requirement object, with at most 16
requirements per notifier. The requirement name normally matches the
`secretRef` field in `config_schema`; set `config_key` when it does not.

| Common field | Required | Type and meaning |
| --- | --- | --- |
| `injection_mode` | yes | One of the six canonical names in [Credentials](#credentials-the-guest-never-sees-one) |
| `required` | no | Boolean; defaults to `false`. A missing required channel credential stops delivery before a grant is issued |
| `config_key` | no | String naming the channel config field that holds the opaque network-credential reference |
| `ttl_seconds` | no | Positive integer lifetime for the one-delivery credential grant; defaults to 300 |
| `allow` | no | A further narrowing map. Its closed keys are `hosts`, `schemes`, `methods`, `paths`, and `ports`; ports are integers and every other member is a string |

Mode-specific fields are listed under [The six canonical injection
modes](#the-six-canonical-injection-modes). Unknown fields are rejected during
package import. In particular, do not supply a nested `inject` map or the
northbound-only `allowed_hosts`, `allowed_ports`, `allowed_methods`,
`allowed_paths`, or `allowed_schemes` aliases. The platform constructs the host
wire map only from the validated typed fields. Arbitrary `fixed_*` literals are
also rejected; a plugin can put non-secret fixed values in its own request body,
while the one host-generated fixed value required by OAuth is declared exactly
as `fixed_grant_type: password`.

The credential grant inherits the assignment's effective `allowed_domains` and
`allowed_ports` after package approval and assignment overrides have narrowed
them. If the channel config contains a concrete URL, the grant narrows again to
that endpoint. The form and OAuth modes instead narrow to their declared exact
targets. A notifier therefore needs an explicit manifest `permissions` scope;
credential injection never creates egress authority on its own. For OAuth, both
the upstream request host/port and the token-exchange host/port must remain
inside the assignment's effective permissions. A package can import with a
broad enough permission but later fail closed at delivery if an assignment
override removes either endpoint.

### inbound

| Key | Default | Notes |
| --- | --- | --- |
| `enabled` | `false` | |
| `signature` | `none` | Must be `hmac_sha256` when `enabled` is true |
| `signature_header` | - | Required when the signature is `hmac_sha256`; it is where the verifier reads the signature from |
| `timestamp_header` | - | |
| `tolerance_seconds` | `300` | Positive, at most `900` |
| `path_suffix` | - | Required when enabled |

An enabled callback that signs nothing accepts any caller who guesses the route,
so the signed shape is mandatory rather than a default an author can forget, and
an unbounded replay window is refused.

### The block and the capability are two halves of one thing

A package with `notifications:` entries **must** request `notify:v1`, and a
package requesting `notify:v1` **must** declare notifier entries. Either half
alone is inert - the agent refuses a notifier without the capability, and the
capability with no notifier grants nothing - so the validator refuses both
shapes rather than importing something that cannot work.

## `notify:v1` is enforced, not just declared

`notify:v1` is the capability that authorizes notification delivery, and it is
checked by the **agent**, not only by the manifest validator.

That distinction is the whole point. A capability that exists only in an
allowlist is unenforced: the control plane can be convinced to dispatch to a
plugin that never requested the permission, and nothing on the execution path
objects. Two capabilities in the manifest allowlist are exactly that today.
`notify:v1` is not allowed to become the third, so the host refuses a
notification dispatch for an assignment whose capability set omits it, from
**both** entrances to plugin execution. A permission with one guarded entrance is
not enforced.

Three properties of the gate are worth designing around:

1. **It reads the assignment, not the package manifest.** What reaches the agent
   is the *narrowed* capability set: the package's approved capabilities, then
   the assignment's override. An operator who denies `notify:v1` at either step
   lands at the same denial. Declaring it in `plugin.yaml` is necessary and not
   sufficient.
2. **It runs before the module is loaded.** A denied plugin is never
   instantiated, so no part of the delivery request - which carries alert
   content - reaches guest memory.
3. **It fails closed.** An unknown assignment, an absent capability map, and a
   malformed credential grant all deny.

### One export, many notifiers

The host calls the **assignment's** entrypoint - the one exported function the
control plane put on the assignment, taken from the package's top-level
`entrypoint` - and passes `action_key` through in the invocation envelope. A
package that ships several notifiers therefore dispatches on `action_key` inside
that one export.

The per-notifier `entrypoint` in the `notifications:` block is validated and
recorded, but nothing carries it to the host today. Write it truthfully, and do
not build a package that only works if the host honours it.

### What the guest sees

The guest reads its invocation through the host config object. It carries an
`action_invocation` envelope with the delivery's identity
(`delivery_id`, `channel_id`, `action_key`, `provider_key`, `payload_format`,
`dedupe_key`, `is_test`), the addressing (`plugin_assignment_id`,
`plugin_package_id`), and the **redacted** rendered payload, merged with the
assignment's own configuration.

A dispatch that cannot be named is refused rather than run: `delivery_id`,
`channel_id`, and `action_key` are what let core correlate the result back to
the row that is the system of record, and a delivery nobody can report on is
worse than one that never ran, because it looks sent.

The command result your plugin submits is passed through unchanged apart from
the correlation identity and the schema defaults - the host is a courier, not an
author of your result shape. It is also only a **wake-up signal**. The delivery
row is always the system of record, and a lost result is recovered by a bounded
periodic sweep rather than by re-deriving state from the command plane. See
[Receipts for agent-routed deliveries](./notifications.md#receipts-for-agent-routed-deliveries).

## Credentials: the guest never sees one

**Secret material never enters guest memory and never travels in the plugin
parameters.** This is a property of the delivery path, not a convention an
author is asked to honour:

- The command payload carries no `secrets`, no `secret_refs`, and no channel
  `config`. It carries the redacted payload.
- The assignment's parameters carry a `credentialref:` sentinel where a
  credential would be, never the credential.
- Trusted-host-only material - a webhook URL whose path is itself the secret -
  travels in a separate host-only field that `get_config` does not surface.
- The credential grant that rides on the delivery **names** a secret; it does
  not carry one. The host resolves the material and injects it at the HTTP
  boundary, after the guest has built its request and before it goes out.

So a plugin does not read a token, cannot log one, and cannot leak one into an
error message. Both SDKs enforce the same shape on their side: the secret
reference is an opaque type that renders a placeholder through every formatting
path, and the SDK-generated error message is bounded and stripped of sentinels
and action-link URLs.

### The six canonical injection modes

`injection_mode` must be one of exactly these six. Every field shown as required
is checked during package import, not deferred until a delivery reaches an
agent.

| Mode | Required typed fields | What the host does |
| --- | --- | --- |
| `http_header` | `name`; optional `scheme` | Sets the named header to the resolved material, prefixed by `scheme` and one space when supplied |
| `bearer_token` | None beyond `injection_mode`; optional `name`, `scheme` | Sets the named header. The normalized defaults are `name: Authorization` and `scheme: Bearer` |
| `basic_auth` | None beyond `injection_mode` | Sets HTTP Basic credentials. The selected credential must expose `username` (or `user`) and `password` material fields |
| `query` | `name` | Adds the resolved material as the named query parameter |
| `form_urlencoded` | `method`, `host`, integer `port`, `path`, and at least one `field_<material-field>: <form-field>` mapping | Adds mapped credential material only when the plugin's HTTPS request exactly matches the method, host, port grant, and path |
| `oauth2_password_bearer` | The upstream `method`, `host`, integer `port`, and `path`; `token_method: POST`, `token_host`, integer `token_port`, and `token_path`; mappings to both `username` and `password`; `fixed_grant_type: password` | Performs the exact HTTPS password-token exchange, then sets the upstream request's `Authorization: Bearer ...` header |
| `oauth2_client_credentials` | The same target and token-endpoint keys as `oauth2_password_bearer`, but mappings to both `client_id` and `client_secret`, and `fixed_grant_type: client_credentials` | Performs the RFC 6749 section 4.4 client-credentials exchange, then sets the upstream request's `Authorization: Bearer ...` header |

For example, `field_account_name: username` reads the `account_name` field from
the resolved credential and writes it to the `username` form field. Mapping
keys and values are identifiers, not credential literals. Target paths start
with `/` and do not include a query or fragment. Target ports are integers in
`plugin.yaml`; the platform emits only string-valued entries to the host grant,
serializing `token_port` as a decimal string and keeping the upstream `port` in
the grant's egress scope.

The two OAuth2 modes run the identical host-side exchange and differ only in
the grant they perform and the two credential fields that grant requires. A
requirement naming one mode while mapping the other's fields is rejected: the
required-field list is per-mode, so `oauth2_client_credentials` mapping
`username`/`password` fails validation even though both mappings are otherwise
well-formed and the grant type is self-consistent.

Neither mode lets the plugin see the long-lived credential. The host performs
the token exchange itself and puts only the derived short-lived bearer token on
the upstream request, so the client secret never crosses the guest boundary.

Shorthand spellings some other surfaces accept - `header`, `http_basic_auth`,
`query_param`, `http_query` - are **not** accepted here, deliberately, so that a
plugin author never learns a spelling one surface accepts and another rejects. A
manifest carrying `header` fails validation in the platform; a delivery grant
carrying `header` fails at the agent.

### No injection mode rewrites a URL path

None of the six touches the URL path. That is not an oversight, and it has one
concrete consequence:

**Slack and Discord incoming webhooks cannot run on the edge route.** Their
incoming-webhook URL carries the secret in the path itself, so there is nothing
for a header, a bearer token, or a query parameter to inject. ServiceRadar
refuses those channels on `edge_agent` at save time and again at dispatch, and
the agent refuses a `url_path` grant on its own account so a dispatch that got
past the control plane some other way still cannot smuggle one through.

Use the **bot-token** mode for those destinations. A bot token is a header
credential, so it injects normally and works on either route.

A URL-path injection mode is out of scope for this version. If it is ever added,
it goes into the host first and the manifest allowlist second, never the other
way around.

## The two execution routes

`execution_route` is a property of the **channel**, not of the plugin, and it
decides which agent runs the module. There is exactly one Wasm host in
ServiceRadar - the runtime inside `serviceradar-agent` - so a plugin-backed
provider always executes on an agent either way:

| Route | Agent |
| --- | --- |
| `control_plane` | the platform-resident agent deployed alongside core |
| `edge_agent` | the site agent named on the channel |

Both use the same command, so a plugin authored for a site agent runs unchanged
on the platform agent. Moving a channel between the two is a configuration edit
plus a plugin assignment, never a repackage. Declare `routes: [control_plane]`
unless your destination genuinely needs the other one.

### `:edge_agent` is only for destinations the platform cannot reach

The edge route exists for exactly one requirement: **a destination that is only
reachable from inside the customer network** - an internal ticketing system, an
on-premises chat server, an SMS gateway on a private segment. It is not a
performance option and it is not a default.

The reason is the command path. `AgentCommandBus` is **at-most-once with no
store-and-forward**: if the target agent has no live control session at the
moment of dispatch, the command is marked offline and returns an error, and
nothing re-drains offline commands when the agent reconnects. This is tracked as
[GitHub issue #3565](https://github.com/carverauto/serviceradar/issues/3565).
It is a property of the current command plane, not a transient bug.

An agent-offline reply is therefore *retryable*, not an immediate failover - a
site that was briefly disconnected is not abandoned on the first missed
heartbeat - and only when the attempts are exhausted does the delivery take its
one failover hop.

### An edge-only escalation policy cannot deliver the "this site went dark" page

This is the configuration that silently guarantees no page at exactly the moment
one is owed, so it is worth stating plainly:

> If every channel an escalation policy can reach is an `edge_agent` channel,
> that policy **cannot** deliver a site-down page. The platform is the component
> that detects the site going dark, and the agent it would have paged through
> went dark with it. There is no queue at the agent to drain when it comes back,
> because the command was never accepted.

Two corollaries:

- **Always give an edge-routed channel a control-plane fallback**, unless you
  genuinely prefer silence to a duplicate.
- `fail_closed` disables failover entirely. It is the right setting for a
  destination whose whole purpose is that it must not be silently substituted,
  and the wrong setting for anything you expect to be paged by.

The UI warns about the edge-only shape on the policy row, in the policy editor,
and on every route bound to the policy, and grades a channel's failover
configuration as you edit it. The warning is not cosmetic. See
[Execution route](./notifications.md#execution-route-control-plane-vs-edge-agent)
for the operator-side detail.

## Binding a provider to your notifier

Once the package is imported and approved, an operator creates a
`NotificationProvider` of type `wasm_plugin` that references the package and
names one notifier by its `action_key`. Three rules apply, and each fails loudly:

- The `action_key` **must** be a `key` declared in that package's
  `notifications:` block. An undeclared key is rejected and the error lists what
  the package actually declares.
- A `wasm_plugin` provider without a package reference is rejected.
- The package must be **approved**, and its approved capabilities must include
  `notify:v1`. Revoking a package disables every provider bound to it.

Then a channel binds to that provider, and delivery follows the ordinary route,
policy, and escalation machinery described in
[Notifications](./notifications.md).

## Shipping display contracts (optional)

A package may ship declarative display contracts that tell the web UI how to
render this notifier's delivery detail and channel health. They are indexed at
runtime from the installed package, so a third-party contract renders **without
a web-ng release**. A contract that this release refuses is dropped with a
diagnostic listed in the admin package panel rather than failing the import, and
a notifier with no contract degrades to the generic view. See
[Telemetry Display Contracts](./telemetry-display-contracts.md).

Display contracts describe widgets declaratively. The nine UI-code key names the
manifest already refuses on an action - `html`, `raw_html`, `javascript`, `js`,
`component`, `component_ref`, `live_view`, `react`, `ui_code` - are refused in a
display contract at any depth, so a contract cannot become a second door into
shipping markup.

## Why a delivery failed

Every failure names itself on the delivery row. The four configuration errors
fail **permanently** on the first attempt rather than consuming the retry
budget: no number of retries approves a package, and the useful behaviour is to
fail over to a channel that can page.

| `error_class` | Meaning |
| --- | --- |
| `plugin_package_unapproved` | The package is staged, denied, or revoked |
| `notify_capability_denied` | The approved capabilities do not include `notify:v1` |
| `plugin_assignment_missing` | The package is approved but not assigned to that agent |
| `platform_agent_unconfigured` | No platform-resident agent is configured for the `control_plane` route |
| `agent_offline` | The agent had no control session. Retryable |
| `agent_command_failed` | The command could not be dispatched. Retryable |
| `command_receipt_timeout` | The command passed its TTL with no result. Handed back to the retry budget, and terminal once the budget is spent |
| `secret_unavailable` | A channel credential could not be resolved. Retryable |
| `payload_format_unsupported` | The rendered format is not one the notifier declares |

At the agent, an addressing failure is distinct from a capability failure:
`missing_notification_target` (the dispatch named neither an assignment nor a
package), `notifier_not_assigned` (this agent runs no assignment of that
package), and `ambiguous_notification_target` (this agent runs more than one
assignment of that package). The last one fails closed on purpose - two
assignments of one package are two channel configurations, so picking either
would deliver the alert to the wrong destination and record it as sent.

## Related pages

- [Notifications](./notifications.md) - the operator guide to channels, routes,
  escalation, suppression, and the Delivery Log.
- [Notification Providers (Declarative)](./notification-providers.md) - the
  no-code tier, and the honest list of what it cannot express.
- [Wasm Plugins](./wasm-plugins.md) - the sandbox, capabilities, permissions,
  signing, and the import workflow.
- [SDKs & Plugin Development](./sdks.md) - the Go and Rust SDKs.
- [Edge Agent Onboarding](./edge-agent-onboarding.md) - getting a site agent
  connected before you can route a channel through it.
