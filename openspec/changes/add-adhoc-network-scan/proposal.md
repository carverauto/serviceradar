# Change: Ad-hoc network sweep/scan from the ServiceRadar console + API

## Why

Operators today run ad-hoc reachability checks the hard way: they SSH to a
jumpserver, hand a bash/PowerShell script a `.csv`/`.txt` of IP addresses,
and loop `ping` (and sometimes port checks) by hand. There is no way to do
this from the ServiceRadar web console, no durable record of what was
scanned or found, and no API for the other tools the team is building that
need to fire ad-hoc scans against arbitrary target lists.

ServiceRadar already has essentially all the machinery: an on-demand,
addressed-to-one-agent command bus (`ServiceRadar.Edge.AgentCommandBus`
over the `ControlStream` bidi RPC), reusable ICMP/TCP/MTR scan engines
(`go/pkg/scan`, `go/pkg/mtr`), an online-agent picker
(`list_online_agents/0`), and the exact "inline IP list -> run now ->
stream progress/results" pattern in the existing `mtr.bulk_run` command.
What's missing is (a) an agent command that accepts a caller-supplied
target+port list for ICMP/TCP (the analog of `mtr.bulk_run`), (b) a
durable, queryable place to keep results, and (c) the web UI + REST API +
RBAC to drive it safely.

## What Changes

### Scan job model — a `ScanRun` aggregate dispatched as one command
- **ADD** an Ash aggregate `ServiceRadar.Scans.ScanRun` (schema `platform`)
  capturing one user-initiated scan: chosen `agent_id`, requested `modes`
  (`icmp` / `tcp` / `mtr`), `ports`, the normalized target list, options
  (timeouts/concurrency/ICMP count/MTR protocol+max-hops), `status`
  (`pending`/`running`/`partial`/`completed`/`failed`), counts, and
  timestamps. One ScanRun dispatches a **single** `scan.run_adhoc` command
  (all requested modes) to the chosen agent.
- **ADD** `AgentCommandBus.dispatch_adhoc_scan/3` (+ concurrency caps and
  `required_capability` gating) mirroring `dispatch_bulk_mtr/3`.

### MTR becomes a first-class sweep mode
- **ADD** `ModeMTR` to `models.SweepMode` so a sweep/scan config carries
  `modes: [icmp, tcp, mtr]` uniformly. The sweep engine runs MTR per target
  via the existing `mtr.Tracer` engine (reuse at the engine level, not a
  second command). This supersedes dispatching a separate `mtr.bulk_run`.
- **EXTEND** the scheduled sweep-profile schema + the Elixir sweep-config
  compiler to allow `mtr` in a profile's modes, and **ADD** an MTR option to
  the Settings sweep-profile editor (alongside ICMP/TCP). Scheduled profiles
  with MTR run it on their interval through the same engine path.

### Agent side (Go) — one ephemeral command handler
- **ADD** `commandTypeAdhocScan = "scan.run_adhoc"` to
  `go/pkg/agent/control_stream.go`, with a handler that builds
  `[]models.Target` from the payload and runs an **ephemeral** sweep for all
  requested modes — ICMP via `NewICMPSweeper`, TCP via `NewTCPSweeper`, MTR
  via `mtr.Tracer` — in throwaway instances scoped to the command. It MUST
  NOT touch the persistent `MultiSweepService`/scheduled sweep config and
  MUST NOT reuse `sweep.run_group`. Streams `CommandProgress` result batches
  for large lists and emits a final summary.
- **ADD** the `scan.run_adhoc` capability to the agent's advertised
  capability set so dispatch can gate on it.

### Results — durable via JetStream (honors the metrics-through-JetStream rule)
- **ADD** an `adhoc-scan-metrics` `MetricBatch` envelope emitted by the
  agent onto the existing `metrics.>` JetStream stream (reusing the
  `metric_envelope.go` builder pattern used by `icmp-metrics` /
  `sweep-metrics`), carrying the `scan_run_id`, per-target availability,
  RTT, and per-port state. The live `CommandResult`/`CommandProgress`
  channel is used **only** for interactive UI progress, not as the source
  of truth.
- **ADD** routing in `ServiceRadar.ResultsRouter` for the
  `adhoc-scan-metrics` source and a new EventWriter processor
  (`event_writer/processors/adhoc_scan.ex`) that persists rows into a new
  hypertable.
- **ADD** migration creating `platform.adhoc_scan_results` as a Timescale
  hypertable (reusing `maybe_create_hypertable` + `add_retention_policy`,
  default 30-day retention) and a read-only Ash resource
  `ServiceRadar.Scans.ScanResult` (`migrate? false`) with `by_scan_run`,
  `by_agent`, `recent` reads. MTR mode writes a reachability summary row to
  `adhoc_scan_results` (`mode="mtr"`) **and** the full per-hop trace to the
  existing `mtr_traces`/`mtr_hops`; the UI and export join both under
  `scan_run_id`.

### Web-ng UI — LiveView
- **ADD** a `ScanLive` LiveView: paste a target list into a textarea, or
  drag-and-drop / upload a `.csv`/`.txt` (reusing `allow_upload` + the
  existing hand-rolled CSV parser). Parse, validate, and de-dupe IPs/CIDRs;
  pick modes (ICMP / TCP+ports / MTR), enter ports, pick the egress agent
  from `list_online_agents/0`. Live progress via the command-bus PubSub
  events; results in a `stream/3` table joined across `scan_results` +
  `mtr_traces`.
- **ADD** export buttons: CSV (reusing the chunked `text/csv` streaming
  controller pattern) and XLSX (via a new `elixlsx` dependency — the one
  net-new library).

### Inventory-scoping guardrail + add-missing
- **ADD** a singleton settings resource
  `ServiceRadar.Scans.ScanPolicySettings` with `restrict_to_inventory
  :boolean` (default `false`), modeled on `DeviceCleanupSettings`. When
  enabled, a scan request SHALL reject any target IP not present in
  inventory (checked via `Device.get_by_ip`), returning the offending IPs.
- **ADD** UI affordances to add the missing IPs to inventory — single add
  and **bulk** add (hundreds) — reusing `ManualDeviceCreator` and the
  existing bulk-import loop, gated on `devices.create` / `devices.import`.
  After adding, the scan can proceed.

### RBAC
- **ADD** a `scans` section to `ServiceRadar.Identity.RBAC.Catalog`:
  - `scans.execute` (run a scan) — default operator+admin.
  - `scans.read` (view runs/results) — default all roles.
  - `scans.export` (CSV/XLSX export) — default all roles.
  - `scans.manage` (toggle the inventory-scoping policy) — default admin.
- **ENFORCE** at three layers: LiveView `mount`/`handle_event`
  (`RBAC.can?`), the new API routes, and an Ash policy on `ScanRun`
  (`scans.execute` on create, `scans.read` on read).

### REST API for external tools
- **ADD** `scope "/api/v1"` `ScanController` routes under the
  `:api_key_auth` pipeline (ApiToken / OAuth client-credentials with a
  `scan.execute` scope), rate-limited via a named pipeline:
  - `POST /api/v1/scans` — body `{agent_id, targets[], modes[], ports[],
    options{}}`; returns the created `ScanRun` (`scans.execute` +
    `scan.execute` scope). Honors the inventory-scoping policy (409 with
    the offending IPs when it blocks).
  - `GET /api/v1/scans/:id` — run status (`scans.read`).
  - `GET /api/v1/scans/:id/results` — paginated results (`scans.read`).
  - `GET /api/v1/scans/:id/export?format=csv|xlsx` (`scans.export`).

## Impact

- **Affected specs**: NEW capability `adhoc-network-scan`.
- **Affected code (high level)**:
  - Go: `go/pkg/agent/control_stream.go` (+ handler file), `go/pkg/agent`
    sweep/scan glue, `go/pkg/agent/metric_envelope.go` (new envelope),
    capability advertisement; proto — **no new service**, the existing
    `CommandRequest`/`CommandResult`/`MetricBatch` messages carry it.
  - Elixir core: `ServiceRadar.Scans.*` (ScanRun, ScanResult,
    ScanPolicySettings), migration for `adhoc_scan_results`,
    `AgentCommandBus.dispatch_adhoc_scan`, `ResultsRouter` route,
    `event_writer/processors/adhoc_scan.ex`, RBAC catalog `scans` section,
    Ash policies.
  - Elixir web-ng: `ScanLive` + views, `ScanController` (API), export
    controller, router entries + rate-limit pipeline, `elixlsx` dep.
- **Compatibility**: purely additive. No existing command types, tables,
  or routes change. MTR reuses its current path unchanged (see follow-up).
- **Follow-up (separate change)**: migrate the on-demand MTR ingestion
  (`mtr.bulk_run` / `mtr.run` -> `StatusHandler` -> `MtrMetricsIngestor`
  Ash write) onto the same JetStream path this change establishes, so both
  ICMP/TCP and MTR results converge on the metrics-through-JetStream rule
  instead of MTR keeping its direct-write exception. Tracked as forgejo
  issue #4669; this change does not block on it.
- **Relationship to paused CLI work**: the `scan.execute` API scope and the
  external-tool auth path align with the paused
  `consolidate-serviceradar-cli` device-auth/`srclient` scope model; the
  external tools can obtain `scan.execute`-scoped tokens through that flow.
