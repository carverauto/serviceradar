# Tasks: Ad-hoc network sweep/scan

## 1. Data model + migrations (serviceradar_core)
- [ ] 1.1 Migration: `platform.adhoc_scan_results` hypertable (reuse
  `maybe_create_hypertable`) with authoritative `network_scope_id` in every
  physical identity/query, a non-null canonical check key for nullable-port
  modes, scheduler-owned `identity_time` as its partition/uniqueness time,
  separate semantic `observed_at`, + 30-day retention (`add_retention_policy`).
- [ ] 1.2 Ash aggregate `ServiceRadar.Scans.ScanRun` (Ash-managed table,
  `platform`) with attributes, status enum, code interface, and policy
  (`scans.execute` create / `scans.read` read / `system_bypass`), binding
  authoritative network scope from the selected agent/site.
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
- [ ] 3.0 Add `ModeMTR` to `models.SweepMode` (`go/pkg/models/sweep.go`);
  teach the sweep engine to run MTR per target via `mtr.Tracer` as a
  first-class mode (used by both ad-hoc and scheduled sweeps).
- [ ] 3.1 Add `commandTypeAdhocScan = "scan.run_adhoc"` +
  `handleAdhocScan` in `go/pkg/agent/control_stream.go` (payload
  `{scan_run_id, plan_id, range_id, range_digest, targets, ports, modes,
  timeout_ms, concurrency, icmp_count, mtr_protocol, mtr_max_hops,
  traffic_class, assignment_epoch, capability}`), where `targets` is one
  hard-bounded immutable plan page/range, building `[]models.Target`
  and running an ephemeral scan for all requested modes (ICMP
  `NewICMPSweeper`, TCP `NewTCPSweeper`, MTR `mtr.Tracer`) in throwaway
  instances. MUST NOT touch `MultiSweepService`/scheduled config or reuse
  `sweep.run_group`.
- [ ] 3.2 Emit rate-limited count/watermark `CommandProgress` plus
  `CommandAck`/TTL handling and a bounded final summary `CommandResult`; do not
  put per-target or per-hop result rows on the command channel.
- [ ] 3.3 Emit the sole durable per-target/per-hop copy from the agent as
  canonical `SweepObservationBatchV1` and correlated `MtrTraceBatchV1` events
  (see 4.2/4.3), never republished by core and never written directly by
  agent/gateway. Feed each completed host/trace directly into the bounded
  builder/spool and release it; forbid run-wide host or completed-trace slices.
- [ ] 3.4 Advertise the `scan.run_adhoc` capability in the agent hello.
- [ ] 3.5 Go tests: payload parse, target build, ICMP/TCP/MTR result
  mapping, progress batching. `gofmt` + BUILD.bazel updates;
  `bazel build //go/pkg/agent/... //go/pkg/scan/... //go/pkg/sweeper/...`.

## 3b. Scheduled sweep-profile MTR (Go engine + Elixir compiler + Settings UI)
- [ ] 3b.1 Sweep engine accepts `mtr` in `SweepModes` for scheduled sweeps
  (reuse the 3.0 engine work).
- [ ] 3b.2 Elixir sweep-profile schema + the sweep-config compiler
  (`SweepJobs`/sweep-config path) accept `mtr` in a profile's modes and emit
  it into the compiled agent sweep config.
- [ ] 3b.3 Settings sweep-profile editor LiveView: add an MTR mode option
  alongside ICMP/TCP (+ MTR options: protocol, max hops).

## 4. Dispatch + ingestion (serviceradar_core)
- [ ] 4.1 `AgentCommandBus.dispatch_adhoc_scan/3` (concurrency caps), mirroring
  `dispatch_bulk_mtr`. Require `scan.run_adhoc`, `edge-results:v1`, the configured
  minimum agent/gateway version, and complete gateway/stream/consumer readiness
  before probing.
  Persist an immutable plan, split large target lists into bounded independently
  fenced assignments, and scheduler-attest `interactive` only within configured
  target/probe/duration/result budgets; select `bulk` or reject larger work.
- [ ] 4.2 Keep `scan.run_adhoc` command progress bounded and UI-only; correlate
  it by `scan_run_id` and do not republish authoritative result rows from core.
- [ ] 4.3 Extend the canonical sweep/MTR EventWriter projectors so
  `source=ad_hoc` writes `adhoc_scan_results` and correlated full traces to
  `mtr_traces`/`mtr_hops`; do not add `adhoc-scan-metrics`.
- [ ] 4.4 Treat command progress as a live estimate, reconcile authoritative
  `ScanRun` status/counters from canonical execution/projection events, and
  publish bounded notifications so LiveView pages newly persisted rows.
- [ ] 4.5 ExUnit: dispatch gating, router routing, processor persistence
  (`:integration` where a DB is needed).

## 5. Web-ng LiveView
- [ ] 5.1 `ScanLive` mount (gate `scans.read`; `scans.execute` for the run
  action); targets textarea + `allow_upload(:targets)` + `phx-drop-target`;
  parse/validate/de-dupe via the existing CSV parser.
- [ ] 5.2 Options form (modes, ports, agent picker via
  `list_online_agents/0`); submit one logical `ScanRun` whose dispatcher emits
  bounded all-mode assignments, without a separate `mtr.bulk_run`.
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
- [ ] 8.3a Verify a plan larger than one command becomes multiple bounded
  assignments, completed hosts/traces become queryable before terminal state,
  RSS stays independent of total target count, caller priority cannot promote
  bulk work, and interactive progress remains bounded during bulk catch-up.
- [ ] 8.4 `openspec validate add-adhoc-network-scan --strict`.
- [ ] 8.5 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
  and `--project elixir/serviceradar_core`.
- [ ] 8.6 Verify dependency/rebase compatibility with
  `unify-sweep-results-proto` and issue #4669.
