# Change: Add Starlink integration plugin (inventory, telemetry, alerts, management)

## Why
Operators running fleets of Starlink terminals and routers have no way to see them in
ServiceRadar: terminals do not appear in inventory, their link quality is not trended,
vendor alerts never become events, and routine service-line operations (replacing a
terminal, moving it between managed accounts, changing a plan) are done by hand in the
vendor portal with no audit trail next to the rest of the network.

Starlink exposes an OAuth2-protected cloud Management API (V2), a telemetry API
(streaming and last-value query), and device-local APIs on each terminal and router.
ServiceRadar already has most of the building blocks (host-proxied HTTP, host-side OAuth2
token exchange, credential rules, device discovery, OCSF events, JetStream metrics,
northbound actions over the agent command bus, dashboard packages), but several SDK gaps
block a clean implementation: no gRPC host capability, response headers dropped by
default, no typed SDK surface for the OAuth2 client-credentials broker grant, the latest
SDK work is untagged, and the dashboard SDK has no typed action or event API.

## What Changes
- Add a first-party Go WASM plugin package `go/cmd/wasm-plugins/starlink/`, built with
  `serviceradar-sdk-go`, shipping two manifests from one module:
  - `starlink-cloud`: polls the Management API V2 and telemetry API through one service
    account per credential rule (`target_cardinality: single`).
  - `starlink-local`: runs on site agents and reads the device-local APIs of terminals and
    routers reachable on that LAN.
- **Inventory**: poll the Management API on a schedule to discover user terminals and
  routers and add/update them in ServiceRadar inventory through
  `serviceradar.device_discovery.v1` complete snapshots. Identity keys on the vendor
  device ID only; public IPs (shared behind carrier-grade NAT) are never identity.
- **Telemetry**: drain the telemetry stream into `serviceradar.metric.v1` records emitted
  through `EmitTelemetry` (JetStream first, persisted by `event_writer`), never into plugin
  results or directly into a database.
- **Alerts to events**: map vendor alert codes (always through the per-response enum
  metadata, never a hard-coded table) to OCSF events with a declared signal schema and
  condition keys, so the agent's existing condition debounce emits raise/clear
  transitions. Propose manifest `alert_rules` (created disabled) for the alerts that need
  paging.
- **Management actions** (northbound actions over the agent command bus, all
  `destructive` + `requires_confirmation` except reboot):
  - reboot user terminal / router;
  - swap the terminal on a service line (composed, checkpointed multi-step flow);
  - move a terminal between managed accounts (composed, checkpointed multi-step flow);
  - change service-line product, deactivate, reactivate.
- **Credentials**: a `starlink` credential profile with an OAuth2 client-credentials auth
  method (client ID, client secret, optional managed account number). The agent host
  performs the token exchange and caches the token; the guest never sees the secret.
- **Local API**: vendor-documented diagnostics (gRPC `get_diagnostics`, router HTTPS
  diagnostics JSON) plus community-documented read-only methods (`get_status`,
  `get_history`) behind an explicit opt-in. Local control methods (stow, power save,
  factory reset) are out of scope. Message encodings are hand-authored minimal
  definitions; no vendor proto file is copied into the repository.
- **SDK and host gaps closed as part of this change**:
  - host-proxied unary gRPC capability (`grpc_unary`, h2c and TLS) in the agent WASM
    runtime, with Go and Rust SDK wrappers and local dev-host support;
  - named HTTP response-envelope mode with headers (plus `Retry-After` helpers) in both
    SDKs; the existing default mode is unchanged;
  - typed SDK surface, fixtures and docs for the `oauth2_client_credentials` broker grant;
  - tagged SDK releases (Go `v2.2.0`, Rust next minor) that the plugin pins;
  - typed `actions` and `events` APIs plus React hooks in `serviceradar-sdk-dashboard`,
    and server-side enforcement of `requires_confirmation` for dashboard-launched actions.
- **Go module fetching**: standardize `GOPRIVATE`/`GONOSUMDB`/`GOPROXY=direct` handling for
  `github.com/carverauto/*` modules across Bazel, CI, plugin templates and SDK READMEs (and
  fix the SDK README's missing `/v2` module path). No new proxy infrastructure.
- **Dashboard (secondary)**: a Starlink fleet dashboard package built with
  `serviceradar-sdk-dashboard` that reads SRQL frames and launches the management actions.

## Impact
- Affected specs:
  - `starlink-integration-plugin` (new)
  - `plugin-sdk-go`
  - `wasm-plugin-system`
  - `wasm-plugin-builds`
  - `dashboard-sdk`
  - `northbound-actions` (delta against the pending `add-northbound-action-integrations`)
- Affected code:
  - `go/cmd/wasm-plugins/starlink/**` (new), `build/wasm_plugins/plugin_inventory.bzl`
  - `go/pkg/agent/plugin_runtime_*.go` (new gRPC host function, capability gating)
  - `elixir/serviceradar_core/lib/serviceradar/plugins/**` (capability allowlist)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/dashboard_frame_channel/actions.ex`
    (confirmation enforcement)
  - `.bazelrc`, `build/wasm_plugins/build_wasm_binary.sh`, `.github/workflows/*wasm*`,
    `js/cli/templates/plugin-go/**`, `docs/docs/wasm-plugins.md`, `docs/docs/sdks.md`
  - `github.com/carverauto/serviceradar-sdk-go` (gRPC, HTTP envelope, OAuth grant types,
    release `v2.2.0`)
  - `github.com/carverauto/serviceradar-sdk-rust` (parity for the same surfaces)
  - `github.com/carverauto/serviceradar-sdk-dashboard` (typed actions/events, hooks)

## Non-Goals
- No device-local control methods (stow/unstow, power save, GPS inhibit, factory reset).
- No use of the removed V1 Management API or the retired legacy enterprise host.
- No new account-ownership transfer beyond what the documented V2 primitives allow; if a
  composed flow is rejected by the vendor, the action fails with the vendor error and a
  checkpoint, it does not retry around the rejection.
- No Starlink secrets in plugin config, device metadata, results, logs, or URLs.
- No private Go module proxy service.
- No multitenancy or per-customer routing.
