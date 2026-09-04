# Change: Expose sweep diagnostics through SRQL and MCP

## Why

When several sweep groups or agents target one device, nothing in the query
surface says which scanner profile, sweep group, vantage point, or requested
protocol produced a given result. Devices imported from CSV and tagged `rids`
are configured for TCP ports 3001, 443 and 4502 yet report ICMP-only
availability, and an operator cannot inspect the compiled sweep configuration
or the per-execution protocol outcome to find out why.

Two structural gaps make this unanswerable today rather than merely tedious:

- `platform.device_agent_availability` is unique on `(device_uid, agent_id)`,
  so a second sweep group reaching the same device through the same agent
  overwrites the first. The losing result is gone, not hidden.
- The results ingestor receives per-port outcomes carrying
  `available: true|false` and keeps only the open ports
  (`sweep_results_ingestor.ex` `open_ports/1`). Closed and no-response TCP
  ports are discarded before write, so no query can distinguish "TCP was never
  requested" from "TCP was requested and refused".

Tracks GitHub issue #4167.

## What Changes

- Persist per-port scan coverage: `sweep_host_results` gains `scanned_ports`,
  plus denormalized `agent_id` and `sweep_group_id` so a result carries its own
  vantage point and group identity. Closed and no-response ports become
  derivable as `scanned_ports` minus `open_ports`.
- Add `platform.sweep_coverage_daily`, a per-day rollup keyed by device, sweep
  group and agent, written by a daily Oban worker that runs before sweep data
  cleanup. Raw host results stay at their 7 day retention; the rollup keeps
  overlap and last-writer history for 400 days.
- Add seven read-only SRQL entities: `sweep_groups`, `sweep_profiles`,
  `sweep_executions`, `sweep_results`, `sweep_coverage`, `device_sweep_overlap`
  and `sweep_compiled_config`.
- Expose the compiled sweep configuration through a named-column allowlist that
  never carries the `compiled_config` blob, because that blob holds SNMP and
  mapper credential material for other compilers.
- Register the new entities in the SRQL catalog, in the live `EntityAccess`
  permission map, and in the MCP cookbook. No new MCP tools: `execute_srql`,
  `get_srql_catalog` and `lookup_srql_docs` are generic and inherit the
  entities.
- Close the `EntityAccess` token-order bypass. The gate anchors on `^in:` while
  the parser accepts `in:` anywhere, so `limit:1 in:<entity>` skips it. This is
  pre-existing and affects every gated entity; it is a prerequisite here because
  `sweep_compiled_config` is admin-gated and a bypassable gate is no gate.
- Admit `sweep_coverage` to the time-window allowlist. Entities outside it are
  capped at 90 days, which would reject the 400-day history the rollup exists
  to serve.

## Impact

- Affected specs: `sweep-jobs`, `srql`, `mcp`
- Affected code:
  - `elixir/serviceradar_core`: migration for `sweep_host_results` columns and
    `sweep_coverage_daily`; `sweep_results_ingestor.ex`; new rollup worker
    alongside `sweep_data_cleanup_worker.ex`; `SweepHostResult` resource.
  - `rust/srql`: `schema.rs`, `models/`, `parser/entity.rs`, `parser/ast.rs`,
    `query/` per entity, `translate.rs`, `engine.rs`, `viz/`, entity examples.
  - `elixir/web-ng`: `srql/catalog.ex`, `priv/mcp/srql-cookbook.md`.
- Migration required. No agent, proto or wire-format change: the per-port data
  is already in the payload and is currently dropped at ingest.
- Read-only for operators. No credential material is exposed.
