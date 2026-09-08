---
title: Notification Providers (Declarative)
---

# Authoring a Declarative Notification Provider

ServiceRadar ships nine chat and paging destinations out of the box, and roughly
85% of every other notification destination in existence is one sentence: **POST
this JSON body to this URL with these headers.** The declarative provider tier
exists so that you can add one of those yourself.

**No code. No release. No Wasm toolchain.** You write a document - YAML or JSON -
describing the request, paste it into **Settings > Notifications > Providers**,
and the platform has a new provider. There is no Elixir module behind the shipped
catalog either: delete the catalog file and the platform loses nine destinations,
not a line of delivery code.

This page is the authoring reference for that document. To page Discord or
Slack for the first time, see the
[Notifications Quickstart](./notification-quickstart.md). For routes,
escalation, suppression, and the Delivery Log, see
[How Notifications Work](./notifications.md).

## Before you start

- You need the `notifications.providers.manage` permission. See
  [Permissions](./notifications.md#permissions).
- A declarative provider always runs on the **control plane**. There is no
  plugin-backed edge execution path for an uploaded document, so `routes` may
  only be `[control_plane]`. See
  [Execution route](./notifications.md#execution-route-control-plane-vs-edge-agent).
- Every outbound URL must be HTTPS, on port 443, resolving to a public address.
  The validator refuses what it can decide from the document alone; the outbound
  URL policy runs again on the rendered URL at request time.

## What this tier is, and where it stops

A declarative provider is one HTTP request: one method, one URL, a set of
headers, and one body, with substitutions. That is the whole execution model,
and it is what the tier can honour.

| You want | Tier |
| --- | --- |
| POST/PUT/PATCH a rendered body to a URL | Declarative. This page |
| Conditionals, loops, arithmetic, value mapping, a second request | `wasm_plugin` |
| Message threading, attachments, an inbound callback endpoint, a resolve-update request | `wasm_plugin` |
| Egress from inside a customer network | `wasm_plugin` on the edge route |

`capabilities` may therefore declare only `send`, `test`, and `rich_payload`.
`threading`, `inbound_callback`, `attachments`, and `resolve_update` are refused
with a message pointing at the plugin tier. `send` and `test` are both
**mandatory** in every tier, so that "test-send before saving" works uniformly.

Everything in the right-hand column above is
[Notification Plugins (Wasm)](./notification-plugin-authoring.md).

Everything the document cannot express is listed honestly in
[What the format cannot express](#what-the-format-cannot-express). Read that
section before you start writing, not after.

## A complete worked example

This is the seeded `gotify` provider, written as YAML. It exercises nearly every
feature of the format: a non-secret config field substituted into the URL, a
credential in a header, a JSON body mixing a literal number with templates, a
status contract, and a correlation id read out of the response.

```yaml
schema_version: 1
key: gotify
display_name: Gotify
description: >-
  Send an alert to a self-hosted Gotify server as an application message.
  Priority is fixed at 5, which is what makes an Android client alert rather
  than sit silently in the tray.
icon: gotify
capabilities: [send, test]
payload_formats: [plain]
routes: [control_plane]
config_schema:
  $schema: "http://json-schema.org/draft-07/schema#"
  title: Gotify channel configuration
  type: object
  additionalProperties: false
  required: [base_url, app_token]
  properties:
    base_url:
      type: string
      title: Server URL
      description: >-
        The Gotify server, for example https://gotify.example.com. It must pass
        the outbound URL policy: HTTPS, and a host that resolves to a public
        address.
      format: uri
      maxLength: 2000
    app_token:
      type: string
      title: Application token
      description: >-
        The token of the Gotify application messages are posted as (not a
        client token). Stored as a credential reference.
      secretRef: true
      credentialKind: api_token
request:
  method: POST
  url: "{{ config.base_url }}/message"
  headers:
    X-Gotify-Key: "{{ secrets.app_token }}"
  body_format: json
  body:
    priority: 5
    title: '{{ alert.severity | upper }}: {{ alert.title | truncate: 200 | default: "ServiceRadar alert" }}'
    message: |-
      {{ alert.message | truncate: 2000 }}

      Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})
      Rule: {{ rule.name | default: "n/a" }}

      Open: {{ links.alert }}
      Acknowledge: {{ links.acknowledge }}
success:
  status: [200]
failure:
  retryable_status: [408, 429, "500-599"]
  retry_after_header: retry-after
response:
  external_correlation_id:
    from: body
    path: id
```

Four details in that document are worth noticing before the reference sections
explain them:

- `base_url` is an ordinary property, so it is addressed as `config.base_url`.
  `app_token` is marked `secretRef: true`, so it is addressed as
  `secrets.app_token` and is **not** addressable as `config.app_token`.
- `X-Gotify-Key` is a credential-shaped header name, so its value has to come
  from a `secrets.*` reference. A literal token there is refused.
- `priority: 5` is a literal JSON number written into the document. It is not a
  substitution, because a substitution always renders a string.
- The body is a **document whose leaves are templates**, not a hand-written JSON
  string. That distinction is the single most common authoring mistake; see
  [A JSON body is a document, not a string](#a-json-body-is-a-document-not-a-string).

## The document, field by field

The format is **closed**. Any key that is not listed below, at any level, is
rejected by name and path - a typo'd key that was silently ignored would be a
setting that quietly did nothing.

### Top level

| Key | Required | What it is |
| --- | --- | --- |
| `schema_version` | yes | Integer. `1` is the only version this platform reads |
| `key` | yes | The provider key. Lower-case letter, then letters, digits, underscores, or hyphens, up to 63 characters. It becomes `provider_key` |
| `display_name` | yes | Single line, 120 characters or fewer |
| `capabilities` | yes | A list from `send`, `test`, `rich_payload`. `send` and `test` are mandatory |
| `payload_formats` | yes | A list from `slack_blocks`, `discord_embed`, `markdown`, `plain`, `html`, `pagerduty_v2`, `json`. At least one. The renderer negotiates the notification body against this list |
| `config_schema` | yes | The JSON Schema the channel form is generated from |
| `request` | yes | The one HTTP request. See [request](#request) |
| `success` | yes | Which statuses mean delivered. See [Status handling](#status-handling) |
| `failure` | yes | Which statuses are worth retrying |
| `description` | no | 1000 characters or fewer |
| `icon` | no | An icon **name** the UI looks up - lower-case letters, digits, underscores, hyphens. Never markup |
| `routes` | no | Defaults to `[control_plane]`, which is also the only legal value |
| `timeout_ms` | no | Positive integer, at most 120000. Defaults to the HTTP transport's 15000 |
| `response` | no | Where the destination's own message handle is. See [response](#response) |

`html` appears in `payload_formats` and is fine there: the nine refused names in
[The nine refused key names](#the-nine-refused-key-names) are **key** names, not
values.

### config_schema

`config_schema` is a JSON Schema object, and it is what the channel form is
generated from. It is validated by the same schema validator every ServiceRadar
plugin manifest uses.

- Root keys: `$schema`, `$defs`, `type`, `title`, `description`, `properties`,
  `required`, `additionalProperties`. Use `type: object` and
  `additionalProperties: false`.
- Property types: `string`, `integer`, `number`, `boolean`, `array`, `object`.
- Property keys include `title`, `description`, `default`, `enum`, `minimum`,
  `maximum`, `minLength`, `maxLength`, `pattern`, `format`, `items`,
  `secretRef`, and `credentialKind`.
- `format` may be `uri`, `email`, or `password`.
- `credentialKind` may be `api_token`, `username_password`, `ssh_private_key`,
  `certificate`, `snmp`, or `opaque`.

Two rules the validator enforces on top of the schema itself:

1. **A credential-shaped property name must be marked `secretRef: true`.** Name
   segments split on `_` and `-` are checked against `token`, `secret`,
   `password`, `passwd`, `passphrase`, `apikey`, `credential`, `credentials`,
   `key`, and `authorization`. A property called `api_key` that is not a secret
   ref would put a token in the channel's non-sensitive `config` column, so it is
   refused. (`auth_mode` is fine: the match is on whole segments, not
   substrings.)
2. **Only scalar, non-secret properties are addressable in templates.** A
   property declared `type: object` or `type: array` cannot be substituted into a
   string, so `config.<that field>` is not a legal path and the error says so by
   name.

Write good `title` and `description` text on every property. It is the only
documentation the operator configuring a channel will see.

### request

| Key | Required | What it is |
| --- | --- | --- |
| `method` | yes | `POST`, `PUT`, or `PATCH`. A declarative provider always sends a body, so `GET` and `DELETE` have no shape here |
| `url` | yes | A template string. Must start with `https://` or with a substitution that supplies the scheme |
| `headers` | no | A mapping of header name to template string. At most 32 |
| `body_format` | yes | `json`, `form`, or `text`. See [Body formats](#body-formats) |
| `body` | yes | The shape `body_format` requires |

**URL rules.** The literal parts of the URL may not contain whitespace -
percent-encode with the `url_encode` filter instead. A fully literal URL is
checked for scheme (`https` only), host, and port (443 only) at save time. A URL
that begins with a substitution has its scheme decided at request time by the
outbound URL policy, because only channel configuration knows the effective host.
The URL is capped at 4000 bytes.

**Header rules.**

- Header names are stored downcased, which is how they appear in the preview and
  in the canonical stored document. Two spellings of one name are rejected as a
  duplicate.
- A newline in a header **value** is header injection and is refused at save
  time. A newline that arrives later through a substituted alert title is
  collapsed to a space at render time rather than being allowed to fail the
  delivery.
- A credential-shaped header name (same segment list as above -
  `Authorization`, `X-Gotify-Key`, `X-Api-Token`, ...) must carry a `secrets.*`
  reference in its value. A literal token, or one read from `config`, is refused:
  the stored definition is not a sensitive column.
- For a `json` or `form` body, a `Content-Type` header must be a literal media
  type rather than a template, and it must agree with `body_format`:
  `application/json` for `json`, `application/x-www-form-urlencoded` for `form`.

You do not need to set `Content-Type` at all. The transport sets it from
`body_format`.

### success and failure

```yaml
success:
  status: [200, 204]
failure:
  retryable_status: [408, 429, "500-599"]
  retry_after_header: retry-after
```

An entry is either an integer status code or an inclusive range written as a
string, `"500-599"`. At most 32 entries per list. See
[Status handling](#status-handling) for the rules that make these two lists
mean something.

### response

Optional. It names where the destination's own handle for the message lives, so
that a later interaction can be tied back to the delivery that produced it. The
value is recorded on the delivery row as `external_correlation_id` and truncated
to 512 bytes.

```yaml
response:
  external_correlation_id:
    from: body
    path: result.message_id
```

```yaml
response:
  external_correlation_id:
    from: header
    header: X-Request-Id
```

`path` is a dotted path of **literal map keys**, or a list of them, at most 8
segments deep. It is deliberately not JSONPath: JSONPath is an expression
language, and this tier does not have one.

## Supply format: YAML or JSON

Both are accepted, and the upload form sniffs which you pasted: a leading `{`
selects JSON, everything else is YAML. The top level must be a mapping in either
case. Input is capped at 64 KiB.

What gets **stored** is the canonical form of what you wrote, not your bytes.
Header names come back downcased, a single status code comes back as an integer
and a range as a `"low-high"` string, and `failure.retry_after_header` is always
present with its resolved value even if you omitted it. That is deliberate: the
stored document is exactly the one that was validated, which is also what makes
version comparisons stable.

### YAML anchors and aliases do not work

Do not use them. Write the value out, or supply JSON. Three separate things go
wrong, and none of them is loud:

1. **There is nowhere legal to define an anchor.** The format is closed, so a
   top-level `defaults: &defaults` holder key is refused as an unknown key
   before its contents are ever considered.
2. **Merge keys are not implemented.** `<<: *defaults` does not merge. The key
   survives literally, and you get an error at a path you never wrote:
   `request.<<1 is not a key of request`, followed by "is required" errors for
   every field you thought you had merged in.
3. **An alias to a flow-style collection silently decodes to its first scalar.**
   Given `common: &h {Content-Type: application/json}`, the alias `*h` decodes
   to the **string** `Content-Type`, not to the mapping. Aliases to block-style
   collections and to plain scalars happen to resolve correctly today, but the
   format does not promise it, and the difference between the two spellings is
   invisible when you are reading your own document.

The rendered-request preview in the upload form is where an author sees that this
happened. If a header block or a body section is missing, or a value is a
suspiciously short string that matches one of your keys, an alias collapsed.

## The two template namespaces

Templates use the platform's one restricted substitution engine - the same
catalog, the same seven filters, and the same rejection of anything resembling
code that notification bodies use. See
[Templates and rendering](./notifications.md#templates-and-rendering) for the
variable catalog and the filter list.

A provider definition adds exactly two namespaces on top of it, and **they are
disjoint**:

| Namespace | Holds | Comes from |
| --- | --- | --- |
| `config.<field>` | Ordinary channel configuration | A property in this document's `config_schema` **without** `secretRef: true` |
| `secrets.<name>` | A resolved credential | A property **with** `secretRef: true` |

The legal leaves under each come from this document's own `config_schema` and
nowhere else, so a path naming a field you did not declare is a save-time error
rather than an empty string during an incident.

A `secretRef` property is **not** addressable under `config.`. The channel's
`config` column holds the credential *reference*; the value never goes there. A
document therefore cannot address the reference and mean the value, and
`{{ config.app_token }}` on a secret field is refused with "unknown variable
path" plus the list of what this document does declare.

**The name under `secrets.` is the property name with a trailing `_secret_ref`
stripped.** A property called `app_token` is `secrets.app_token`; a property
called `app_token_secret_ref` is *also* `secrets.app_token`. It matches the key
the credential broker resolves into.

### Credentials must come from secrets

Put the credential in a header (or in the URL, for an incoming-webhook
destination whose token is in the path) and read it from `secrets.*`:

```yaml
request:
  headers:
    Authorization: "GenieKey {{ secrets.api_key }}"
```

A credential-shaped header whose value carries no `secrets.*` reference is
rejected at save time:

```
request.headers.authorization carries a credential, so its value must come from
a secrets.* reference such as "Bearer {{ secrets.token }}". A literal credential
would be stored in the provider definition, which is not a sensitive column.
```

At dispatch, every resolved secret is registered as a sensitive value, so a token
cannot survive into an error message, a delivery's result summary, or a log line.
The preview never resolves a secret at all - it renders a marker.

## Body formats

### A JSON body is a document, not a string

This is the mistake that costs an evening, so it is refused rather than accepted.

**Wrong.** `body` is a hand-written JSON string with substitutions inside it:

```yaml
request:
  body_format: json
  body: '{"title": "{{ alert.title }}", "message": "{{ alert.message }}"}'
```

That is rejected at save time, and the reason is not stylistic. The first alert
whose title contains a double quote - `Disk "sda1" full` - produces broken JSON
and a 400 from the destination, during an incident. On top of that, the HTTP
layer encodes the body as a term, so a rendered string would go out as a JSON
*string literal* rather than as the object you drew.

**Right.** `body` is a JSON object (or array) whose **leaves** are templates:

```yaml
request:
  body_format: json
  body:
    title: "{{ alert.title }}"
    message: "{{ alert.message }}"
```

Nesting, arrays, literal numbers, booleans, and nulls are all fine - the seeded
`teams` entry is a nested Adaptive Card with an array of blocks. The rules are:

- Keys must be literal. Only values may be templates.
- A number, boolean, or null leaf is passed through as the JSON value you wrote.
- At most 200 keys in any one object; at most 12 levels of nesting in the whole
  document.

### Form and text bodies

`body_format: form` takes a **flat** mapping of field name to template string. A
number or a boolean value is allowed and is sent as its string form. Field names
must be literal.

`body_format: text` takes a single template string.

## Status handling

The document decides what the destination's answer means. Nothing else does.

- **`success.status` is 2xx only.** The HTTP layer never follows redirects, so a
  3xx is never a success, and a document that called a 4xx a success would record
  deliveries as `sent` that the destination rejected.
- **`failure.retryable_status` may not cover a 2xx**, and may not overlap
  `success.status`. A 2xx means the destination accepted the payload; retrying
  would send the notification twice.
- **Everything in neither list is a permanent failure.** This includes a 200 you
  did not list. Some destinations answer 200 with an error body, and a delivery
  recorded as `sent` that nobody received is the silent failure the whole platform
  exists to prevent. When it happens, the delivery's error message says so
  explicitly: "The destination answered 200, which this provider's definition
  does not list in success.status".
- **`failure.retry_after_header`** names the header carrying a backoff hint,
  because `Retry-After` is not universal. Only a delta-seconds value is read; an
  HTTP-date is ignored rather than guessed at, and the value is clamped to one
  hour.

A good default for an HTTP destination is `[408, 429, "500-599"]`: a request
timeout, a rate limit, and a server-side fault are worth repeating, and every
other non-2xx is a request this provider will keep getting wrong.

Retry itself - how many attempts, and the backoff between them - belongs to the
channel, not to the document. See
[Retry, failover, and escalation](./notifications.md#retry-failover-and-escalation-are-three-different-things).

## The nine refused key names

These nine names are refused as **keys**, case-insensitively, at any depth of the
document's own structure:

```
html  raw_html  javascript  js  component  component_ref  live_view  react  ui_code
```

A provider describes its UI declaratively through `config_schema` and never ships
markup or code.

**They are allowed inside `request.body`.** Body keys belong to the
*destination's* API vocabulary, not to ServiceRadar's document structure:
`component` is a real PagerDuty Events API v2 field that incident grouping
depends on, and `html` is a real field in more than one chat API. Refusing those
key names in a body protects nothing - ServiceRadar never interprets a request
body as UI - and would make the tier unable to express destinations it is meant
to cover. The seeded `pagerduty` entry uses `component` for exactly this reason.

The controls that still apply everywhere, including inside the body, are the ones
that actually matter:

- **Every string value** in the document is scanned for the code constructs
  `<%`, `%>`, `{%`, `%}`, and Elixir string interpolation. One anywhere means
  somebody expected a programming language, and the document is refused.
- **Every template** is validated against the published variable catalog and the
  fixed seven-filter set, with this document's `config.*` and `secrets.*` paths
  added. An unknown path or an unknown filter is a save-time error.

A body key cannot smuggle markup, because a body value cannot.

## Limits

Bounds exist so that a pasted document cannot turn one dispatch into an unbounded
traversal. If you are near one of these, reconsider the shape.

| Limit | Value |
| --- | --- |
| Document size | 64 KiB |
| Nesting depth | 12 levels |
| Total values | 2000 |
| Key length | 200 bytes |
| `display_name` | 120 characters |
| `description` | 1000 characters |
| `request.url` | 4000 bytes |
| Headers | 32 |
| Status entries per list | 32 |
| Keys per JSON object | 200 |
| Correlation path | 8 segments |
| `timeout_ms` | 120000 |
| Substitutions per template | 200 |
| Filters per substitution | 4 |

YAML decoding additionally runs in a heap-bounded process with a five-second
budget, so an expansion bomb comes back as a parse error instead of a memory
event.

## Testing a definition before you save

The upload form is at **Settings > Notifications > Providers > New provider**.
Work in this order.

1. **Paste the document.** Validation runs as you type. Every problem is reported
   at once, each naming the path it is at
   (`request.headers.authorization`, `config_schema.properties.api_key`) and what
   to do about it. Nothing summarises or collapses those messages, so fix them
   from the top.
2. **Read the rendered-request preview.** It shows the exact method, URL,
   headers, body, the channel fields your `config_schema` will generate, and your
   success and retryable status sets. It is rendered by the same function that
   performs a real delivery, so it cannot disagree with what would be sent.

   Every substitution point renders as a marker naming itself - `alert.title`
   appears as `<alert.title>`, `config.base_url` as `<config.base_url>`. No
   secret is resolved, read, or rendered. This is where you catch the three
   things a validator cannot: a substitution that landed in the wrong field, a
   body whose shape is not what you drew, and a YAML alias that collapsed.
3. **Save.** The provider is created as a **draft**. Activate it before binding
   channels to it.
4. **Create a channel** on the new provider and fill in the form your
   `config_schema` generated.
5. **Test-send from the channel, before saving it.** The test is a real delivery
   with the real configuration and the real resolved credential - it is literally
   the same code path, not a rehearsal of it. The resulting row is marked
   `is_test` in the Delivery Log, creates no alert, and counts toward nothing.
   Test-send needs `notifications.test.send`, which is deliberately separate from
   channel edit because it performs real egress with real credentials.
6. **Confirm in the Delivery Log**, not at the destination. The log is where a
   200-that-was-not-a-success, an unresolved variable, or a refused URL is
   visible.

## Versioning and rollback

Uploading over an existing declarative provider does not rewrite it. It writes a
**new version**: `definition_version` goes up by one, and the previous document
stays readable in the provider's version history.

That is not bookkeeping. Every delivery records the `provider_version` that
rendered it, so a delivery from three weeks ago keeps pointing at the exact
document that produced it, and the Delivery Log stays explicable after you edit
the provider.

- **Rollback is a new version too.** Restoring version 1 while you are on version
  2 writes version 3, carrying version 1's document. History is append-only, and
  you can roll back a rollback.
- **An upload always sets the provider's source to `uploaded`**, including an
  upload over one of the seeded catalog entries. That is what makes your edit
  survive upgrades: it diverges the managed fingerprint, and the next release
  leaves your document alone.
- **A seeded entry you disable stays disabled** across every future release.
- **An uploaded `key` that already belongs to a provider in another tier is
  refused.** An uploaded document never replaces a native or plugin provider.

## What the format cannot express

These four limits are properties of the format, not oversights. Each one was hit
while authoring the shipped catalog. If you run into one with no warning you will
assume you did something wrong, so they are written down.

### 1. No HTTP Basic auth

`base64` is not one of the seven filters, and there is no `auth` block in the
document. A destination that authenticates with a Basic header - the
base64 of `user:token` - cannot be expressed directly. Zulip, Jira, ServiceNow,
and Twilio are all in that group.

The only workaround is to declare a `secretRef` field holding the **already
encoded** `user:token` blob and write `Basic {{ secrets.basic_auth }}`. That
validates, and it costs more than it looks like:

- the operator has to base64-encode by hand before they can configure a channel,
  and again on every credential rotation;
- the field's label lies about what it holds, so the next operator will paste a
  password into it;
- a mis-encoded blob fails only at the first real send, which is during an
  incident.

The supported answers are a `wasm_plugin` provider, or upstream work: a `base64`
filter, or an `auth` block that reaches the HTTP transport's existing Basic
support. Do not ship a catalog entry built on the pre-encoded workaround.

### 2. No value mapping

The engine substitutes and filters. It does not translate one vocabulary into
another. ServiceRadar severities are `info`, `warning`, `critical`, and
`emergency`. PagerDuty accepts `critical`, `error`, `warning`, `info`. Opsgenie
accepts `P1` through `P5`. There is no expression in this format that maps one
onto the other, and sending `emergency` to PagerDuty is a 400 on the one alert
that mattered most.

**The pattern you will need most** is the one the catalog uses: pin the
destination-side value as an `enum` config field with a `default`, carry the real
ServiceRadar severity in the text and in the structured details, and let the
operator create **one channel per severity band**, routed separately.

```yaml
config_schema:
  properties:
    severity:
      type: string
      title: PagerDuty severity
      description: >-
        The severity every event from this channel carries. PagerDuty accepts
        only critical, error, warning, and info, which is not the ServiceRadar
        set - emergency has no PagerDuty equivalent and would be rejected - and
        a request template cannot map one vocabulary onto another. The
        ServiceRadar severity is in the summary and in custom_details. Use one
        channel per severity band to route them differently.
      enum: [critical, error, warning, info]
      default: critical
request:
  body:
    payload:
      severity: '{{ config.severity | default: "critical" }}'
      summary: '[{{ alert.severity | upper }}] {{ alert.title | truncate: 900 | default: "ServiceRadar alert" }}'
      custom_details:
        serviceradar_severity: "{{ alert.severity }}"
```

Write the reason into the property's `description`, as above. The operator
reading the channel form is the person who has to understand why there are two
severities.

### 3. A key or a header cannot be omitted conditionally

There is no "include this only when it has a value". Every key you write is
always present in the request. Two distinct consequences:

**An optional `config` field with no `default:` is a permanent failure, not an
empty value.** If a channel does not supply `config.username` and the template is
a bare `{{ config.username }}`, the delivery fails permanently and **no request is
sent**, with an error naming the field:

```
request.body.username substitutes {{ config.username }}, which this channel does
not supply. Set it on the channel before sending; a request with a hole where a
credential or a configured value belongs would be rejected by the destination.
```

So an optional field must either be dropped from the document entirely - letting
the destination's own default apply, which is what an incoming webhook is for -
or guarded with a `default:` filter that guarantees a non-blank value:

```yaml
username: '{{ config.username | default: "ServiceRadar" }}'
```

**An empty string is not an absent key.** Once the field is set to `""`, or a
`default: ""` supplies one, the key still goes out with an empty value.
Mattermost will look for a channel named `""` rather than fall back to the
webhook's own.

The severe case is an optional credential. An `Authorization` header guarded with
`default: ""` renders as the bare scheme - `Bearer` with nothing after it - which
a destination rejects as **malformed auth**, not as an anonymous request. That is
why the seeded `ntfy` entry *requires* an access token rather than offering one.
A document cannot say "send this header only when it has a value".

Note that unresolved *notification* variables behave differently and deliberately
so: `{{ device.name }}` on an alert with no device renders empty, the delivery
proceeds, and the variable is listed in the delivery's `result_summary` under
`unresolved`. An alert genuinely may not carry a device, and dropping a page over
it would be the failure the platform exists to prevent.

### 4. Every substitution renders a string

There is no typed substitution. `{{ config.priority }}` produces `"5"`, not `5`.
A destination that requires a JSON number, boolean, or null must get a **literal**
in the document:

```yaml
body:
  priority: 5
  disable_web_page_preview: true
```

That is why the seeded `gotify` entry hardcodes `priority: 5` instead of offering
it as a config field, and why `telegram` writes `disable_web_page_preview: true`
as a literal. If a destination requires a *configurable* number, this tier cannot
supply it; that is `wasm_plugin` work.

## What ships in the catalog

Nine first-party declarative providers are seeded and reconciled on upgrade like
any other managed record. Each is a request-template document and nothing else -
no Elixir module, no registry entry.

| Key | Endpoint | Auth | Success |
| --- | --- | --- | --- |
| `pagerduty` | `POST {events base}/v2/enqueue` | `routing_key` in the body | 202 |
| `opsgenie` | `POST {api base}/v2/alerts` | `Authorization: GenieKey ...` | 202 |
| `mattermost` | `POST <incoming webhook url>` | the URL is the credential | 200 |
| `rocketchat` | `POST <incoming webhook url>` | the URL is the credential | 200 |
| `googlechat` | `POST <space webhook url>` | the URL is the credential | 200 |
| `teams` | `POST <workflow webhook url>` | the URL is the credential | 200, 202 |
| `telegram` | `POST https://api.telegram.org/bot<token>/sendMessage` | token in the path | 200 |
| `ntfy` | `POST {base}/` | `Authorization: Bearer ...` | 200 |
| `gotify` | `POST {base}/message` | `X-Gotify-Key: ...` | 200 |

`pagerduty` is the one that closes the "integrate with real on-call rather than
reimplement it" story, and it does so with a document. Its `dedup_key` is
`alert.id`, so one ServiceRadar alert maps to one PagerDuty incident and repeated
occurrences update it instead of opening a second.

Every seeded entry is parsed by the validator at **compile** time. A malformed
catalog entry fails the build with the validator's own message, rather than being
skipped at boot by a warning nobody reads. First-party origin buys no relaxed
validation path.

Any of the nine can be edited or disabled, and both survive upgrades. See
[Versioning and rollback](#versioning-and-rollback).

### Deliberately not shipped

`Zulip`, `Jira`, `ServiceNow`, and `Twilio` all authenticate with HTTP Basic,
which this format cannot express - see
[No HTTP Basic auth](#1-no-http-basic-auth). Jira and ServiceNow additionally
need per-instance field mapping (project key, issue type, Atlassian Document
Format) that a fixed body template cannot carry. They are `wasm_plugin` tier
work. A catalog entry whose request shape is guessed is worse than one not
shipped.

## Troubleshooting

**"is not a key of ..."** - the format is closed and you have a typo, or you are
using a key from another system. The message lists every key that section
accepts.

**"unknown variable path ..."** - the path is not in the published catalog and
not declared by this document's `config_schema`. The message ends with the exact
list of `config.*` and `secrets.*` paths this document does declare, and names
any field that is unaddressable because it is an object or an array.

**"names a credential but is not marked secretRef: true"** - rename the field, or
mark it `secretRef: true` and address it as `secrets.<name>`.

**"contains the code construct ..."** - a value somewhere in the document has
`<%`, `{%`, or string interpolation in it. This engine is restricted substitution
only; expressive logic is `wasm_plugin` work.

**The preview is missing a section you wrote** - a YAML alias collapsed. See
[YAML anchors and aliases do not work](#yaml-anchors-and-aliases-do-not-work).

**A delivery failed permanently with `http_200`** - the destination answered 200
and your `success.status` does not list it, or it answered 200 with an error body
and you should be reading that body. Add the code to `success.status` only if the
destination really does mean success by it.

**A delivery failed with "which this channel does not supply"** - an optional
`config` or `secrets` path has no value and no `default:`. See
[limit 3](#3-a-key-or-a-header-cannot-be-omitted-conditionally).

**Deliveries stop after a provider edit** - check the provider's status. A
provider must be active, and a disabled provider suppresses its channels with
reason `channel_disabled`. See
[Suppression is auditable](./notifications.md#suppression-is-auditable-nothing-is-dropped-silently).
