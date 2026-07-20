# Tasks: Ad-hoc network sweep/scan

## 1. Data model + migrations (serviceradar_core)
- [ ] 1.1 Migration: `platform.adhoc_scan_results` hypertable (reuse
  `maybe_create_hypertable`) + 30-day retention (`add_retention_policy`).
- [ ] 1.2 Ash aggregate `ServiceRadar.Scans.ScanRun` (Ash-managed table,
  `platform`) with attributes, status enum, code interface, and policy
  (`scans.execute` create / `scans.read` read / `system_bypass`).
- [ ] 1.3 Ash read resource `ServiceRadar.Scans.ScanResult` (`migrate?
  false`) with `by_scan_run` / `by_agent` / `recent` reads.
- [ ] 1.4 Singleton `ServiceRadar.Scans.ScanPolicySettings`
  (`restrict_to_inventory :boolean`), modeled on `DeviceCleanupSettings`,
  `scans.manage`-gated writes.
- [ ] 1.5 Register the `Scans` domain / resources; `mix ash.codegen` +
  migration review.

## 2. RBAC (serviceradar_core)
- [ ] 2.1 Add `scans` section to `Identity.RBAC.Catalog`
  (`execute`/`read`/`export`/`manage`, default roles per design).
- [ ] 2.2 Map `scans.*` in web-ng `Authorization.Permissions` (Permit) if
  using resource-gating; confirm catalog key-existence test passes.

## 3. Agent side (Go)
- [ ] 3.1 Add `commandTypeAdhocScan = "scan.run_adhoc"` +
  `handleAdhocScan` in `go/pkg/agent/control_stream.go` (payload
  `{scan_run_id, targets, ports, modes, timeout_ms, concurrency,
  icmp_count}`), building `[]models.Target` and running an ephemeral
  `NetworkSweeper.RunOnce` (ICMP `NewICMPSweeper`, TCP `NewTCPSweeper`).
- [ ] 3.2 Progress batching (reuse `mtr.bulk_run` progress shape) +
  `CommandAck`/TTL handling.
- [ ] 3.3 `adhoc-scan-metrics` `MetricBatch` builder in
  `metric_envelope.go` (carry `scan_run_id`, per-target/per-port fields);
  emit on the `metrics.>` JetStream path (NOT a direct DB write, NOT the
  CommandResult as source of truth).
- [ ] 3.4 Advertise the `scan.run_adhoc` capability in the agent hello.
- [ ] 3.5 Thread `scan_run_id` into the `mtr.bulk_run` payload (additive).
- [ ] 3.6 Go tests: payload parse, target build, ICMP/TCP result mapping,
  progress batching, envelope contents. `gofmt` + BUILD.bazel updates;
  `bazel build //go/pkg/agent/...`.

## 4. Dispatch + ingestion (serviceradar_core)
- [ ] 4.1 `AgentCommandBus.dispatch_adhoc_scan/3` (concurrency caps,
  `required_capability: "scan.run_adhoc"`), mirroring `dispatch_bulk_mtr`.
- [ ] 4.2 `ResultsRouter` clause for `adhoc-scan-metrics`.
- [ ] 4.3 EventWriter processor `event_writer/processors/adhoc_scan.ex` ->
  `adhoc_scan_results`; wire into the processor registry.
- [ ] 4.4 Update `ScanRun` status from progress/terminal events (PubSub).
- [ ] 4.5 ExUnit: dispatch gating, router routing, processor persistence
  (`:integration` where a DB is needed).

## 5. Web-ng LiveView
- [ ] 5.1 `ScanLive` mount (gate `scans.read`; `scans.execute` for the run
  action); targets textarea + `allow_upload(:targets)` + `phx-drop-target`;
  parse/validate/de-dupe via the existing CSV parser.
- [ ] 5.2 Options form (modes, ports, agent picker via
  `list_online_agents/0`); submit -> `dispatch_adhoc_scan` (+ `mtr.bulk_run`
  when MTR selected).
- [ ] 5.3 Inventory-scoping check before dispatch (`Device.get_by_ip`);
  when blocked, show offending IPs + add-missing UI.
- [ ] 5.4 Add-missing: single + bulk via `ManualDeviceCreator` /
  bulk-import loop, gated `devices.create`/`devices.import`.
- [ ] 5.5 Results `stream/3` table joining `ScanResult.by_scan_run` + MTR
  traces; live updates from command-bus PubSub.
- [ ] 5.6 Route + nav entry under the authenticated/permitted live_session.

## 6. Export
- [ ] 6.1 CSV export via chunked `send_chunked` `text/csv` controller
  (reuse the existing pattern), joined result set for a `scan_run_id`.
- [ ] 6.2 Add `elixlsx` to `web-ng/mix.exs`; XLSX workbook builder + route.
- [ ] 6.3 Gate both on `scans.export`.

## 7. REST API
- [ ] 7.1 `Api.ScanController`: `create/show/results/export` following
  `Api.DeviceController` shape; scope from `conn.assigns[:current_scope]`.
- [ ] 7.2 Router: `/api/v1/scans*` under `:api_key_auth`; `POST` also under
  `RequireOauthScope` (`scan.execute`) + a `:rate_limit_scans` pipeline.
- [ ] 7.3 Honor the inventory-scoping guardrail (409 + offending IPs).
- [ ] 7.4 OpenAPI/Swagger entry; controller tests (happy, missing scope,
  missing permission, guardrail-block, export).

## 8. Verification
- [ ] 8.1 `mix test` (core + web-ng); `:integration` where DB-backed.
- [ ] 8.2 `go test ./go/pkg/agent/...` + `bazel build //go/pkg/agent/...`
  and the agent binary.
- [ ] 8.3 Manual e2e on the docker mTLS stack: run ICMP+TCP+MTR from
  `ScanLive` against a small list, confirm results land via JetStream in
  `adhoc_scan_results`, MTR in `mtr_traces`, CSV+XLSX export, and the
  inventory guardrail block + bulk add-missing.
- [ ] 8.4 `openspec validate add-adhoc-network-scan --strict`.
- [ ] 8.5 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
  and `--project elixir/serviceradar_core`.
- [ ] 8.6 File the MTR-onto-JetStream follow-up change/issue.
