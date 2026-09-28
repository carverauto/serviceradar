## 1. Proposal Approval
- [x] 1.1 Review and approve the OpenSpec proposal.
- [ ] 1.2 Resolve open questions: dashboard package location, multi-grant dispatcher support, terms-of-service review for unofficial local methods.

## 2. Go Module Fetching
- [ ] 2.1 Standardize `GOPRIVATE`/`GONOSUMDB` for `github.com/carverauto/*` in `.bazelrc`, `build/wasm_plugins/build_wasm_binary.sh`, `.github/workflows/wasm-plugins.yml` and `external-wasm-plugin.yml`.
- [ ] 2.2 Update `js/cli/templates/plugin-go/**`, `docs/docs/wasm-plugins.md`, `docs/docs/sdks.md` and `docs/docs/notification-plugin-authoring.md` with the same settings.
- [ ] 2.3 Fix the `serviceradar-sdk-go` README install line to the `/v2` module path and document the fetch settings.

## 3. Agent Host gRPC Capability
- [ ] 3.1 Add the `grpc_unary` host function and `grpc_request` capability in `go/pkg/agent` (pass-through bytes codec, h2c and TLS transports).
- [ ] 3.2 Enforce destination permissions, h2c-only-to-`allowed_networks`, `max_open_connections`, timeout and response cap before and during the call.
- [ ] 3.3 Advertise `grpc_request` in agent capabilities and add it to the core plugin capability allowlist and admission checks.
- [ ] 3.4 Add agent tests: allowed call, denied destination, undeclared capability, h2c outside allowed networks, oversized response, timeout.

## 4. SDK Changes (serviceradar-sdk-go, serviceradar-sdk-rust)
- [ ] 4.1 Go: unary gRPC wrapper, typed status errors, local dev-host gRPC handler.
- [ ] 4.2 Go: `ResponseModeEnvelope` constant plus `Header` and `RetryAfter` helpers.
- [ ] 4.3 Go: typed credential broker grant/inject constants and builders, shared `oauth2_client_credentials` fixtures, local dev-host bearer injection.
- [ ] 4.4 Rust: parity for 4.1-4.3 against the same shared fixtures.
- [ ] 4.5 Tag and release Go `v2.2.0` and the next Rust minor; update changelogs.
- [ ] 4.6 If `field_*` token-form mappings cannot omit a blank optional field, add `omit_if_blank` support in `go/pkg/agent/plugin_runtime_oauth.go` with tests.

## 5. Starlink Cloud Plugin
- [ ] 5.1 Scaffold `go/cmd/wasm-plugins/starlink/` (module, pinned tagged SDK, committed `vendor/`, `BUILD.bazel`, `main_tinygo.go`/`main_stub.go`), and register both bundles in `build/wasm_plugins/plugin_inventory.bzl`.
- [ ] 5.2 Write `plugin.yaml` (`starlink-cloud`): capabilities, permissions, config schema, credential profile with OAuth2 client-credentials grant, split read/management allow lists, inventory source, signal schemas, proposed alert rules, actions.
- [ ] 5.3 Management API client: response envelope parsing, index and cursor pagination, 429/`Retry-After` handling, per-run request budget.
- [ ] 5.4 Inventory: terminals, routers, service lines to `device_discovery.v1` complete snapshots with the identity rules from design D3.
- [ ] 5.5 Telemetry: bounded stream draining, name-based column decoding, enum decoding, metric mapping to `serviceradar.metric.v1` via `EmitTelemetry`, gap detection.
- [ ] 5.6 Alerts: query-based level alerts to OCSF events with condition keys, enum-only code mapping, unknown-code events, severity table.
- [ ] 5.7 Tests with synthetic fixtures only: pagination, partial snapshot, identity (shared public IP, placeholders), column reorder, unknown alert code, secret rejection in guest config.

## 6. Management Actions
- [ ] 6.1 Confirm whether the northbound dispatcher supports multiple named credential grants per invocation; implement it with tests if not.
- [ ] 6.2 Implement reboot actions for terminal and router.
- [ ] 6.3 Implement `starlink.swap_terminal` with preflight, checkpointed steps, L2VPN re-apply and verification.
- [ ] 6.4 Implement `starlink.move_terminal_account` with two credential requirements, checkpointed steps and verification.
- [ ] 6.5 Implement product change, deactivate and reactivate with preflight and verification.
- [ ] 6.6 Emit per-step OCSF audit events; test resume-at-step, preflight rejection, vendor error propagation and 429 deferral.

## 7. Starlink Local Plugin
- [ ] 7.1 Write `plugin.local.yaml` (`starlink-local`) with `grpc_request`, restricted networks and ports, and `enable_unofficial_methods` (default false).
- [ ] 7.2 Hand-author minimal protobuf encoders/decoders for `get_diagnostics`, `get_status` and `get_history` (only the fields used, unknown-field tolerant, no copied vendor proto).
- [ ] 7.3 Read router HTTPS diagnostics when a domain is configured.
- [ ] 7.4 Attach local metrics and events to vendor-ID devices; never create devices or emit LAN addresses as identity.
- [ ] 7.5 Tests: diagnostics-only default, unofficial-method degradation, no control methods issued, convergence with cloud identity.

## 8. Dashboard SDK and Host
- [ ] 8.1 `serviceradar-sdk-dashboard`: typed `actions.list/invoke` and `events.subscribe`, `useDashboardActions`/`useDashboardEvents` hooks, confirmation helper; release a new minor.
- [ ] 8.2 web-ng: enforce `requires_confirmation` for dashboard-launched invocations with a confirmation bound to action and targets; tests for missing and mismatched confirmations.

## 9. Starlink Dashboard (secondary)
- [ ] 9.1 Build a Starlink fleet dashboard package with `serviceradar-sdk-dashboard`: inventory table, link-quality trends, active alerts, and confirmed management actions.
- [ ] 9.2 Publish it through the standard dashboard package flow with synthetic sample frames.

## 10. Documentation and Validation
- [ ] 10.1 Document service-account setup (dedicated account for ServiceRadar, required permissions), credential rules, telemetry single-consumer constraint, alert mapping, actions and their risks, and the local plugin with the unofficial-method caveat.
- [ ] 10.2 Run `openspec validate add-starlink-integration-plugin --strict`, Go tests for the plugin and agent, SDK test suites, and the Bazel bundle build; record any check not run.
