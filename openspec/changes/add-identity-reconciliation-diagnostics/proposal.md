# Change: Expose device identity reconciliation diagnostics through SRQL and MCP

## Why

Diagnosing an identity-reconciliation incident currently requires direct CNPG
access. GitHub issue #4229 records the case that forced it: an inventory-count
drop and lost CSV classification could not be explained through any supported
product interface, so the investigation joined `ocsf_devices`, `merge_audit`,
`device_revival_audit`, and `device_identifiers` by hand in psql.

Auditing the current surface shows two different gaps, and only one of them is
an exposure problem:

**Already queryable.** `in:devices deleted:true` works today
(`rust/srql/src/query/devices/filters.rs`), and `deleted_at`, `deleted_by`, and
`deleted_reason` are already projected (`rust/srql/src/models/inventory.rs`).
Acceptance criterion 1 is closer than the issue assumes.

**Persisted but unexposed.** `platform.merge_audit`,
`platform.device_revival_audit`, and `platform.device_identifiers` all exist and
are indexed, and none has an SRQL entity or an MCP tool. The merge chain is
walked only inside `Identity.Resolver.latest_merge_target/2`; nothing renders
it.

**Not persisted at all.** `DuplicateSweep.reconcile_duplicates/1` builds a
complete stats map — candidates, duplicate/mergeable/blocked components, blocked
devices, merges, errors, duration — then `Logger.info`s it and discards it
(`duplicate_sweep.ex`). `JobSchedule.run_identity_reconciliation` logs the same
map a second time and throws it away. `report_blocked_components/1` computes
`largest_component`, emits a `Logger.warning` and a `:telemetry` event, and
returns `:ok`. The configured per-run cap is normalized at the top of the run
and then consulted only inside the merge reduce; whether a run *hit* the cap is
never recorded anywhere. Acceptance criteria 5 and 6 cannot be met by a
read-only change, because the data does not exist to read.

## What Changes

- Add five SRQL entities: `in:merge_audit`, `in:device_revival_audit`,
  `in:device_identifiers`, `in:identity_reconciliation_runs`, and the derived
  `in:identity_evidence_edges`.
- Add `in:merge_audit chain:<device_uid>`: a recursive walk of the merge graph
  in both directions, projecting `depth` and `direction`, over the existing
  `merge_audit_from_device_created_idx` and `merge_audit_to_device_idx`.
- Add `in:identity_evidence_edges device:<device_uid>`: the connected component
  of devices joined by shared `(identifier_type, identifier_value, partition)`,
  projecting `depth`, `direct` (an edge incident to the seed) and
  `cross_partition`. A seed filter is mandatory.
- Project `matches_current_facts`, `owner_deleted`, and the owner tombstone
  fields on `in:device_identifiers`, so an operator can tell current
  corroborated ownership from a historical identifier without a second query.
- Add `platform.identity_reconciliation_runs`, one row per sweep run, and write
  it from `DuplicateSweep` — including on the `rescue` path, and including
  `max_merges_configured` and `merge_cap_reached`, which the stats map does not
  carry today. `report_blocked_components/1` returns the largest component
  instead of `:ok`.
- Add two task-oriented MCP tools, `trace_device_identity` and
  `explain_identity_reconciliation`, implemented as Ash actions that compose
  bound SRQL through the existing `Mcp.Runner`.
- Register every new entity and alias under `devices.view` in
  `SRQL.EntityAccess`, and add a test that every parser alias resolves to a
  permission rather than falling through the unknown-entity passthrough.
- Key-allowlist `merge_audit.details` and `device_identifiers.metadata` in the
  SRQL projection instead of returning the raw jsonb.
- Retain reconciliation run rows for a configurable window (default 30 days),
  pruned at the end of each run.

## Non-Goals

- Changing merge, alias, or reconciliation *behavior*. Identifier hygiene,
  merge oscillation, cardinality caps, and the agent/Proxmox bridging work
  belong to `refactor-device-identity-reconciliation`.
- Mutating tools. `unmerge_device` and device deletion stay off MCP; every tool
  and entity added here is read-only.
- A per-run snapshot table of evidence edges. Edges are derived at query time
  from `device_identifiers` so they reflect current state; a snapshot would
  drift from the identifiers it describes and multiply rows per run.
- A `corroborated_at` column on `device_identifiers`. That is a write-path
  change to the hottest identity table in the system and belongs to the DIRE
  refactor.
- A new RBAC catalog key. These entities ride `devices.view`.
- A new UI page or dashboard package. The SRQL catalog, cookbook, and query
  builder are the UI surface for this change.
- Resolving IP / hostname / tag to a seed uid inside SRQL. The MCP tool does
  that with a bound `in:devices` query first.

## Impact

- Affected specs: `srql`, `mcp`, `device-identity-reconciliation`
- Affected code:
  - `rust/srql/src/parser/ast.rs`, `parser/entity.rs`, `parser/filters.rs`
  - `rust/srql/src/query/engine.rs`, `query/translate.rs`, `query/mod.rs`,
    `query/viz/**`, `rust/srql/src/schema.rs`, `rust/srql/src/models/inventory.rs`
  - new `rust/srql/src/query/{merge_audit,device_revival_audit,device_identifiers,identity_reconciliation_runs,identity_evidence_edges}.rs`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/identity/duplicate_sweep.ex`
  - new `elixir/serviceradar_core/lib/serviceradar/inventory/identity/reconciliation_run.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/**` (runs table + indexes)
  - `elixir/web-ng/lib/serviceradar_web_ng/mcp/tools.ex`, `mcp/runner.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/web-ng/priv/mcp/srql-cookbook.md`
  - `integration_tests/srql/tests/comprehensive_queries.rs` and fixtures
- Related (do not reopen): `refactor-device-identity-reconciliation` (merge
  behavior), `add-device-identity-fence` (identity revision), `add-audit-history-page`
  (UI audit surface), `add-srql-advisory-cpe-entities` (entity-registration
  pattern this change follows).
