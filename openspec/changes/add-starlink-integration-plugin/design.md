## Context
Starlink offers three API surfaces relevant to monitoring and management:

1. **Management API V2** (`https://starlink.com/api/public/v2/...`), OAuth2 client
   credentials against `https://starlink.com/api/auth/connect/token`. Tokens live about 15
   minutes; the vendor asks clients to reuse a token until a 401. Access is governed by the
   service account's permission set, not scopes. A token can be scoped to a managed child
   account by adding `account_number` to the token request. Responses share one envelope
   (`errors`, `warnings`, `information`, `isValid`, `content`); most lists are index-paged
   (page size 100, `isLastPage`, `totalCount`), managed-account lists are cursor-paged.
   Documented limits: 250 requests/minute per account, 1000 token requests per 15 minutes
   per client IP. V1 was removed and is not a target.
2. **Telemetry API**: `POST /public/v2/telemetry/stream` (long-poll, columnar, one
   server-side cursor per client ID and account, at-most-once delivery, 8 hour retention,
   online devices only) and `POST /public/v2/telemetry/query` (latest value per device,
   typed JSON, boolean alert fields, filterable by device ID).
3. **Device-local APIs** on the terminal and router LAN: the vendor-documented gRPC service
   `SpaceX.API.Device.Device/Handle` (plaintext HTTP/2, no auth) whose documented request is
   `get_diagnostics`; a vendor-documented router HTTPS diagnostics endpoint (requires an
   enterprise router config with a domain and a publicly trusted certificate); and
   community-documented read methods on the same gRPC service (`get_status`, `get_history`).

ServiceRadar constraints that shape the design: WASM guests have no sockets beyond host
functions; metrics must reach JetStream before any store; integration credentials live in
the unified CNPG credential model and are brokered to the agent host, never to the guest;
plugin inventory flows through `serviceradar.device_discovery.v1` into DIRE; device
revivals and bad merges are expensive to undo, so identity must be conservative.

## Goals / Non-Goals
- Goals: discover and keep current every terminal and router visible to a service
  account; trend link quality; turn vendor alerts into raise/clear events; offer audited,
  confirmed management actions for reboot, terminal swap, account move and plan lifecycle;
  read local diagnostics where an agent shares the LAN; close the SDK gaps listed in the
  proposal so the next integration does not hit them.
- Non-Goals: local control methods, V1 API, a Go module proxy service, plugin-local
  persistent KV state (see Decision 11), multitenancy.

## Decisions

### D1. One Go module, two plugin manifests
`go/cmd/wasm-plugins/starlink/` builds one TinyGo module with two manifests, following the
proxmox `plugin.yaml` / `plugin.console.yaml` precedent:
- `plugin.yaml` -> `starlink-cloud`: capabilities `get_config, log, submit_result,
  emit_telemetry, http_request`; `permissions.allowed_domains: [starlink.com]`,
  `allowed_ports: [443]`; carries the credential profile, inventory source, signal
  schemas, alert rules and actions.
- `plugin.local.yaml` -> `starlink-local`: capabilities `get_config, log, submit_result,
  emit_telemetry, http_request, grpc_request`; `allowed_networks` limited to private and
  link-local ranges; `allowed_ports` limited to the vendor local API ports and 443; no
  credential profile (the local API is unauthenticated).
Both share parsing, metric mapping and alert mapping code. Alternatives: one manifest with
modes (rejected: the cloud plugin must run once per service account while the local one
runs per site agent, and their permission sets differ sharply); two modules (rejected:
duplicated mapping code drifts).

### D2. Credential profile and brokered OAuth2
The cloud manifest declares `integrations.credential_profiles[provider: starlink]` with
auth method `starlink_service_account` (`credential_kind: api_token`), fields
`client_id` (public), `client_secret` (secret), `account_number` (public, optional, for
managed child accounts). Provisioning uses `mode: producer_schedule` (the
`opentext-nom` pattern), not `target_policy`: the agent host applies brokered
credential injection, including OAuth2 token exchange, only to plugin runs in action
mode (`credentialBrokerGrantForHTTP` in `go/pkg/agent/plugin_runtime_http.go`), so
scheduled collection runs as producer-schedule actions (`starlink.inventory.refresh`,
`starlink.telemetry.collect`) with capabilities `producer-schedule:v1`,
`action-result-ingest:v1` and `action-only:v1`. Each schedule declares a
`credential_requirements.starlink_service_account` entry whose grant uses
`resolution_location: agent` and
`inject.type: oauth2_client_credentials` using the existing host keys
(`token_method: POST`, `token_host`, `token_path: /api/auth/connect/token`,
`field_client_id: client_id`, `field_client_secret: client_secret`,
`field_account_number: account_number` when present, `fixed_grant_type:
client_credentials`). The agent host (`go/pkg/agent/plugin_runtime_oauth.go`) already
performs the exchange and caches tokens with an expiry margin and 401 invalidation, so
the guest only ever sees an injected bearer header.

Grant `allow` lists are split by purpose so a scheduled read run cannot mutate:
- `inventory_telemetry` purpose: `GET` on account/service-line/user-terminal/router read
  paths, `POST` only on `/api/public/v2/telemetry/stream`, `/api/public/v2/telemetry/query`
  and `/api/public/v2/data-usage/query` (read operations that the vendor models as POST).
- `management` purpose (per-invocation grants minted by the northbound dispatcher): the
  exact mutating method/path pairs each action needs, and nothing else.
If the host's optional `account_number` field mapping fails validation when the field is
blank, the SDK/host change adds `omit_if_blank` semantics for `field_*` mappings rather
than the plugin constructing token requests itself.

### D3. Inventory discovery and identity
Each scheduled cloud run (default every 15 minutes, operator-tunable) pages through user
terminals, routers and service lines (100 per page, honoring `isLastPage` / `nextKey`) and
emits one `device_discovery.v1` complete snapshot per credential rule with
`source_instance` set to a stable, non-secret hash of the account number and
`snapshot_complete: true` only when every page succeeded. A partial run emits
`snapshot_complete: false` so absence is never inferred from a failed page.

Identity rules (enforced in code and tests):
- `device_id` and `metadata.integration_id` = `starlink:ut:<vendor terminal id>` /
  `starlink:router:<vendor router id>`. Core ignores a plugin `device_id` as an
  identifier and matches on `metadata.integration_id` (identifier type
  `integration_id`), so the vendor ID must be carried there; it is the only strong
  identifier. Kit and dish serials are attributes (`serial` and metadata): core only
  treats a serial as identity for allowlisted vendors, and this change does not add
  one.
- Public IPv4/IPv6 from the `IpAllocs` telemetry or service-line config are stored as
  metadata, never as `ip` identity: carrier-grade NAT shares them across many terminals.
- The vendor-default LAN address of a terminal or router is identical at every site and
  is never emitted as an identifier by either plugin.
- Blank, all-zero or placeholder identifiers are dropped, not emitted.
- Service line number, account number (as a hash in labels, raw in metadata), product,
  nickname, and router->terminal association (`DishId`) are metadata; the
  router->terminal association is emitted as a topology relation, not merged identity.
Devices absent from a complete snapshot follow the external inventory contract's
availability/lifecycle handling; the plugin never requests deletion.

### D4. Telemetry
Each cloud run drains `telemetry/stream` in bounded iterations: `batchSize` sized so a
response stays under the host HTTP response cap, `maxLingerMs` kept well below the request
`timeout_ms`, and an overall per-run budget (iterations and CPU) so a backlog is drained
across runs instead of blowing the resource budget. Column names are read from every
response (`columnNamesByDeviceType`), never assumed by position; enum columns decode via
`metadata.enums`. Rows map to `serviceradar.metric.v1` records emitted with
`EmitTelemetry`, keyed to the D3 `device_id`, with metric names under a `starlink_` prefix
and units normalized (Mbps, ms, ratio, seconds). `IpAllocs` rows update metadata only.

The stream cursor is per client ID and account and delivery is at-most-once. Therefore:
exactly one ServiceRadar consumer per service account (`target_cardinality: single`), docs
tell operators to create a dedicated service account for ServiceRadar, and the plugin
reports a warning status when it observes a data gap longer than its interval. The
8-hour retention bounds recoverable downtime.

### D5. Alerts to events
Alert state comes from `telemetry/query` each run (stateless, level-triggered, named
boolean alert fields). For each device and active alert the plugin emits an OCSF event with
signal schema `com.carverauto.starlink.alert` and `unmapped.condition_key =
starlink:<device_id>:<alert_name>` plus `unmapped.level`; the agent's condition debounce
(`go/pkg/agent/plugin_condition_debounce.go`) turns levels into raise/clear transitions.
When alert codes are read from the stream's `ActiveAlert(s)` column they are mapped only
through `metadata.enums.AlertsByDeviceType` from the same response, because the vendor
reassigns codes and its docs disagree on some values; unknown codes become an
`unknown_alert_<code>` event rather than being dropped or guessed.

The vendor publishes no severities. The plugin ships an explicit, reviewable
alert-name -> severity table (unknown names default to `low`), and the manifest proposes
`alert_rules` (created disabled, per `add-plugin-alert-rules`) for thermal shutdown,
motors stuck, offline, and mast-not-vertical. No rule is proposed for the reboot-pending
alert, which the vendor currently reports unreliably.

### D6. Management actions
Actions are northbound actions on the existing path (UI or dashboard ->
`AgentCommandBus` `plugin.run_action` -> `action_invocation` in the guest config), all
`scopes: [device]` targeting the terminal or router device from D3:

| action_id | safety | steps |
|---|---|---|
| `starlink.reboot_terminal`, `starlink.reboot_router` | standard, confirm | single POST |
| `starlink.swap_terminal` | destructive, confirm | preflight; remove old UT from line; add new UT to account (if needed); add new UT to line; re-apply L2VPN circuits captured in preflight; verify |
| `starlink.move_terminal_account` | destructive, confirm | preflight both accounts; remove UT from its lines; remove UT from source account; add UT under destination account; optionally attach to a destination line; verify |
| `starlink.change_product`, `starlink.deactivate_line`, `starlink.reactivate_line` | destructive, confirm | preflight; single call; verify |

Multi-step actions run as long-running actions: every step boundary is persisted in
`continuation_state` and the action returns `polling`, so an agent restart, timeout or
vendor 429 resumes at the failed step instead of repeating completed ones. Each step
re-reads current vendor state before acting (idempotent resume). Preflight captures
everything needed to roll forward or report (service line, product
`maxNumberOfUserTerminals`, L2VPN circuits) and fails fast when a precondition is unmet.
Every step emits an OCSF audit event. There is no automatic rollback of a vendor-side
mutation; a failed flow reports exactly which steps completed.

`starlink.move_terminal_account` needs tokens for two accounts. It declares two named
credential requirements (`source_account`, `destination_account`), each bound to its own
credential rule. If the northbound dispatcher cannot yet mint more than one grant per
invocation, this change adds that to `northbound-actions` (see the spec delta) rather than
letting a parent-account token be retargeted by an action input.

### D7. Local APIs
`starlink-local` calls the device-local gRPC service through the new `grpc_request` host
capability (D8) with `get_diagnostics` always, and `get_status` / `get_history` only when
the assignment sets `enable_unofficial_methods: true` (default false, labeled unofficial in
the config schema and docs). When a router HTTPS diagnostics domain is configured it is
read through `http_request`. Protobuf messages are hand-authored minimal encoders/decoders
for only the fields used, written from field numbers and names, tolerant of unknown
fields; no vendor proto file is copied (the vendor repository carries no license).

Local results never create devices: the plugin reads the device's own vendor ID from the
response and attaches metrics/events to `starlink:ut:<id>` / `starlink:router:<id>`. If the
cloud plugin has not yet discovered that ID, the local result is still keyed by vendor ID
so the two paths converge on one device.

### D8. Host gRPC capability
A new host function `grpc_unary` (capability `grpc_request`) mirrors `http_request`:
request JSON `{target_host, target_port, authority, method, metadata, message_base64,
timeout_ms, transport: "h2c"|"tls", tls: {server_name, insecure_skip_verify}}`, response
JSON `{grpc_status, grpc_message, headers, trailers, message_base64}`. The agent implements
it with `google.golang.org/grpc` and a pass-through bytes codec, enforcing the same
`allowed_domains` / `allowed_networks` / `allowed_ports` checks as HTTP before dialing,
`max_open_connections`, a response size cap, and a default timeout. `h2c` is only allowed
to destinations inside the manifest's `allowed_networks`. Streaming RPCs are out of scope
(every needed method is unary). Go and Rust SDKs get `GRPC.Unary`-style wrappers; the
local dev host supports a caller-supplied gRPC handler like its HTTP handler. Alternative
rejected: HTTP/2 framing inside TinyGo over `tcp_connect` (heavy, bypasses host
destination checks, untestable in the dev host).

### D9. HTTP response envelope
Both SDKs add a named `ResponseModeEnvelope` constant and helpers (`Header`, `RetryAfter`)
so plugins can honor `Retry-After` on 429 and read pagination headers. The default
`status_body` mode is unchanged for compatibility.

### D10. Typed OAuth2 grant surface in the SDKs
The SDKs add constants and typed builders for grant/inject types already accepted by the
host (`oauth2_client_credentials`, `oauth2_password_bearer`, `bearer_token`, ...), shared
fixtures for an `oauth2_client_credentials` grant, and local dev-host emulation that
injects a bearer header from `SERVICERADAR_CREDENTIAL_*` so plugins can be exercised
without a real token endpoint.

### D11. No plugin KV state
Token caching lives in the host (D2), alert de-duplication in the agent condition debounce
(D5), and the telemetry cursor on the vendor side (D4). A guest KV store would add a
secret-leak surface without a consumer, so it is not added. If implementation finds a real
need (for example a local `get_history` high-water mark), it is proposed separately.

### D12. SDK releases and pinning
SDK changes land in `serviceradar-sdk-go` and `serviceradar-sdk-rust` first, are tagged
(Go `v2.2.0`; Rust next minor), and the plugin pins the tag in `go.mod` with a committed
`vendor/`, like every other first-party plugin. The plugin never pins an untagged commit.

### D13. Go module fetching
`github.com/carverauto/*` modules are not served by the public Go proxy or checksum
database. Every build path (Bazel `.bazelrc` / `build_wasm_binary.sh`, CI workflows, the
`plugin-go` CLI template, SDK and ServiceRadar docs) uses `GOPRIVATE` and `GONOSUMDB` for
`github.com/carverauto/*` (resolving directly from GitHub), plus committed `vendor/` for
hermetic builds. The SDK README install line is corrected to the `/v2` module path.

### D14. Dashboard SDK actions and events
`serviceradar-sdk-dashboard` adds typed `api.actions.list/invoke` and
`api.events.subscribe` (the web-ng host already implements them behind the
`actions.invoke` / `events.subscribe` capabilities), React hooks
(`useDashboardActions`, `useDashboardEvents`) and a confirmation helper. web-ng enforces
`requires_confirmation` server-side for dashboard-launched invocations (an explicit
confirmation token bound to the action and targets), so a dashboard cannot skip it.

### D15. Resolving plugin device identity on metrics, events and alerts
Today nothing maps a plugin's own device ID to the canonical `sr:` device when its
signals are ingested: `timeseries_metrics.device_id` stores `MetricResource.device_id`
raw (`observability/metric_envelope.ex`), OCSF `device.uid` is stored raw
(`event_writer/processors/events.ex`), and alert device resolution
(`alert_lifecycle.ex` via `DeviceCorrelation.resolve/1`) falls back to the agent's own
device when the uid is not canonical. No shipped plugin attributes signals per device,
which is why this has not surfaced.

Core gains one ingest-time resolver used by the metrics processor, the events
processor and alert device resolution: a non-canonical device reference of the form
`<source>:<...>` is looked up as an `integration_id` identifier
(`Identity.DeviceLookup.get_canonical_device/2`) in the gateway-attested partition, and
only when `<source>` is one of the emitting plugin package's declared
`integrations.inventory_sources`, so a plugin cannot attach signals to another
source's devices. A reference that does not resolve is stored as-is and never falls
back to the agent's device. Lookups are batched per ingest batch and cached briefly.
The plugin sets `MetricResource.device_id` and OCSF `device.uid` to the same
`starlink:ut:<id>` / `starlink:router:<id>` value it emits as `integration_id`.

### D16. Condition snapshots and synthesized clears
The agent condition debounce forwards the first observation of every condition key
(including `ok`) and re-forwards unchanged levels every 15 minutes. A stateless plugin
therefore has two bad options for vendor alerts: emit `ok` for every possible alert on
every device each run (floods events), or emit only active alerts (clears never
arrive; the key silently ages out after an hour).

The agent gains condition scopes: a condition event may carry
`unmapped.condition_scope`, and a plugin marks a run's condition set for a scope as
complete with one scope-complete marker record. For a complete scope the agent
forwards raise and level changes as today, synthesizes an `ok` clear for every key it
previously forwarded at a non-`ok` level that is absent from the new set, and does not
forward or refresh `ok` levels that had no prior non-`ok` state. Events without a
scope keep today's behavior. The plugin emits only active alerts with scope
`starlink:<source_instance>:alerts`. Limitation: the debounce state is in memory, so an
alert that clears while the agent is restarting is not cleared by the agent; the
scope-complete marker is forwarded to core with the active key list so core-side
reconciliation can close such alerts (tracked as an open question).

## Risks / Trade-offs
- Vendor alert docs are inconsistent and codes can be reassigned -> map only through
  response metadata; unknown codes are surfaced, not dropped.
- Telemetry stream is at-most-once with one cursor per client -> single consumer per
  service account, gap detection, dedicated-service-account guidance.
- 250 requests/minute is shared with every other tool using the account -> per-run request
  budget, `Retry-After` handling, inventory interval default of 15 minutes.
- Community local methods may change without notice -> opt-in, tolerant decoders, failures
  degrade to diagnostics-only rather than failing the run.
- Moving a terminal between accounts is composed from primitives the vendor does not
  document as one flow -> checkpointed steps, explicit preflight, destructive +
  confirmation, audit events, clear partial-failure reporting.
- Unlicensed vendor proto -> hand-authored minimal encoders only.

## Migration Plan
Additive. New SDK host capability is gated by a new capability name, so existing plugins
and older agents are unaffected; a `starlink-local` package requires an agent version that
advertises `grpc_request` and is refused at admission otherwise. Rollback: unassign the
plugins; inventory rows remain and age out through normal availability handling.

## Open Questions
- Where the Starlink dashboard package lives (in-repo example directory vs. a separate
  public repository).
- Review of vendor terms of service for the community-documented local read methods
  before `enable_unofficial_methods` is documented as supported.
- Whether core should reconcile open condition alerts against forwarded scope-complete
  markers (D16) in this change or a follow-up.
- How operator-launched management actions bind to the account's Starlink credential
  rule -- resolved by the package credential-source contract in
  [Northbound actions on discovered devices](../../../docs/docs/wasm-plugins.md#northbound-actions-on-discovered-devices).
