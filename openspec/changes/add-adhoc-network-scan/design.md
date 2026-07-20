# Design: Ad-hoc network sweep/scan

## Context

Operators run ad-hoc reachability checks from jumpservers with
bash/PowerShell over a CSV of IPs. We want the same, self-service, from the
web console and via API, with a durable record. The build is dominated by
reuse — the two background investigations (Go agent side; web-ng/data side)
found the transport, engines, agent picker, RBAC, inventory add/bulk-add,
hypertable helpers, and CSV export already present. This document records
the two load-bearing decisions (both taken) and the concrete shapes.

## Decisions (taken)

### D1: Durable results via JetStream, live progress via the command channel
Ad-hoc ICMP/TCP results are telemetry (availability, RTT, port state), so
per the AGENTS.md hard rule they MUST traverse JetStream before landing in
CNPG. The agent emits an `adhoc-scan-metrics` `MetricBatch` on the existing
`metrics.>` stream (reusing the `metric_envelope.go` builders that already
produce `icmp-metrics` / `sweep-metrics`); `ResultsRouter` routes the new
source to a new EventWriter processor that writes `adhoc_scan_results`. The
`CommandResult`/`CommandProgress` channel drives **live UI progress only**,
never the system of record. This keeps results subscribable and
rule-compliant while still feeling instant in the UI.

### D2: `ScanRun` aggregate; reuse existing dispatch; MTR stays on its path
One `ScanRun` row models a user's scan and fans out on the agent bus:
- ICMP/TCP -> **new** `scan.run_adhoc` command (inline target+port list),
  modeled byte-for-byte on `mtr.bulk_run`'s inline-list + progress-batch
  shape, running an ephemeral `NetworkSweeper.RunOnce` (no `SweepGroupID`).
- MTR -> the **existing** `mtr.bulk_run`, tagged with `scan_run_id`. No
  second MTR implementation. MTR traces stay in `mtr_traces`/`mtr_hops`;
  the UI and export join them to `adhoc_scan_results` on `scan_run_id`.

Two result stores is the deliberate cost of reusing MTR wholesale; the join
key makes it invisible to users.

## Data model

- `ServiceRadar.Scans.ScanRun` (Ash, `platform`, Ash-managed table):
  `id`, `agent_id`, `modes` (array), `ports` (array), `target_count`,
  `targets` (or a child table for very large lists), `options` (map:
  timeouts, concurrency, icmp_count, mtr protocol/max_hops), `status`,
  `requested_by`, counts (`hosts_up`, `ports_open`), `started_at`,
  `finished_at`. Ash policy: `scans.execute` on create, `scans.read` on
  read, `system_bypass()`.
- `platform.adhoc_scan_results` (raw-SQL hypertable, `migrate? false` Ash
  read resource `ServiceRadar.Scans.ScanResult`): `time TIMESTAMPTZ`,
  `scan_run_id`, `agent_id`, `target_ip`, `mode`, `port` (nullable),
  `available bool`, `response_ms`, `service` (nullable), + PK
  `(time, scan_run_id, target_ip, mode, port)`. Reads: `by_scan_run`,
  `by_agent`, `recent`. Hypertable + 30-day retention via
  `maybe_create_hypertable` / `add_retention_policy`.
- `ServiceRadar.Scans.ScanPolicySettings` (singleton, key `"default"`):
  `restrict_to_inventory :boolean, default: false`. Modeled on
  `DeviceCleanupSettings`. `scans.manage` to write.

## Command + subject names

- Agent command type: `scan.run_adhoc` (new). Payload:
  `{scan_run_id, targets []string, ports []int, modes []string,
  timeout_ms, concurrency, icmp_count}`.
- MTR: existing `mtr.bulk_run`, payload extended with `scan_run_id`
  (additive; existing callers omit it).
- JetStream: reuse the `metrics.>` stream; new `MetricBatch` `Source =
  "adhoc-scan-metrics"`. New `ResultsRouter` clause + EventWriter processor
  `event_writer/processors/adhoc_scan.ex` -> `adhoc_scan_results`.

## Web-ng UI

`ScanLive` under the authenticated + permitted live_session. Targets: a
textarea (paste) plus `allow_upload(:targets, accept: ~w(.csv .txt))` with a
`phx-drop-target` drop zone; parse with the existing hand-rolled CSV parser.
Options: mode checkboxes, port input (for TCP), agent `<select>` from
`AgentCommandBus.list_online_agents/0`. Results: `stream/3` table joining
`ScanResult.by_scan_run` + MTR traces; PubSub `{:command_progress}` /
`{:command_result}` drive live updates. Export buttons hit the export
controller.

## RBAC

New `scans` catalog section: `scans.execute` (operator+admin), `scans.read`
(all), `scans.export` (all), `scans.manage` (admin). Enforced in `ScanLive`
mount/handle_event (`RBAC.can?`), on the API routes, and by the `ScanRun`
Ash policy. Add-missing-device buttons reuse the existing
`devices.create`/`devices.import` gates.

## REST API

`scope "/api/v1", ...Api do pipe_through([:api_key_auth, :rate_limit_scans])`
`POST /scans`, `GET /scans/:id`, `GET /scans/:id/results`,
`GET /scans/:id/export`. `POST` additionally gated on the `scan.execute`
OAuth scope via `RequireOauthScope` (fallback permission `scans.execute`).
Controller shape follows `Api.DeviceController`; a named rate-limit pipeline
mirrors the existing buckets.

## Export

CSV: reuse the chunked `text/csv` `send_chunked` streaming controller
pattern (as in `AuthoredDashboardExportController`). XLSX: add `elixlsx` to
`web-ng/mix.exs` — the single net-new dependency — and a small workbook
builder. Both stream the joined result set for a `scan_run_id`.

## Risks / Trade-offs

- **Two result stores (scan_results + mtr_traces).** Mitigated by the
  `scan_run_id` join; revisited by the follow-up that unifies MTR onto
  JetStream.
- **Large target lists.** Bounded by per-agent concurrency caps (as
  `mtr.bulk_run` does) and progress batching; the ScanRun may store targets
  in a child table rather than a single array column if lists get large.
- **New `elixlsx` dependency.** Isolated to the export module; CSV works
  without it, so XLSX can ship slightly behind if needed.
- **`scan.run_adhoc` is a powerful primitive.** Gated by `scans.execute` +
  the optional inventory-scoping guardrail + agent capability, and every
  run is recorded as a `ScanRun` for audit.

## Follow-up (separate change)

Migrate the on-demand MTR ingestion (`mtr.bulk_run` / `mtr.run` ->
`StatusHandler` -> `MtrMetricsIngestor` direct Ash write) onto the same
JetStream path this change establishes, so ICMP/TCP **and** MTR both satisfy
the metrics-through-JetStream rule and MTR drops its direct-write exception.
Tracked as its own OpenSpec change / issue; this change reuses the current
MTR path unchanged in the interim and does not block on the migration.
