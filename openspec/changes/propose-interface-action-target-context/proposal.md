# Change: Improve interface action target context and device details signal quality

## Why

Interface-scoped northbound actions currently do not provide enough interface context to integrations. A sample interface task can complete with `ifindex: nil`, and even when `ifIndex` is present it is only an SNMP row identifier, not a vendor-stable chassis/module/port identity. Integrations need the fields they explicitly requested from the interface and device schemas, including enough physical-location context to target modular platforms safely.

The device details page is also surfacing low-value or contradictory cards: duplicate alias summaries, opaque "other metadata" counts, integration transport details that do not identify the actual device, per-agent availability that contradicts recent sweep history, and a Logs tab that behaves like an unresolved load even when a bounded log query has no rows.

## What Changes

- Extend interface action target snapshots with requested interface fields such as `if_index`, `if_name`, `if_descr`, `if_alias`, admin/oper status, MAC, speed, and device identity fields.
- Add optional physical interface location context, derived from ENTITY-MIB/ifStack/vendor/API evidence when available, so modular chassis interfaces can be represented as slot/module/subslot/port rather than a bare `ifIndex`.
- Keep plugin authors in control of which supported device/interface fields are required or optional through the action descriptor contract.
- Update Go and Rust SDK target snapshot types/helpers to expose the richer interface context without breaking older plugins.
- Rework device details metadata cards to show useful source-specific facts and hide redundant or implementation-only fields by default.
- Make Agent Availability reconcile with the same sweep observations shown in Recent Sweep History, or clearly explain why no per-agent rollup exists.
- Make the Logs tab execute a bounded SRQL-backed log query and render either rows or a clear empty state without a long spinner/toast path when no logs exist.
- Add topology/backbone regression diagnostics so the topology view can explain why normally connected backbone nodes are being rendered as separate islands.

## Impact

- Affected specs: `wasm-plugin-system`, `plugin-sdk-go`, `plugin-sdk-rust`, `device-inventory`, `build-web-ui`, `network-discovery`
- Related active changes: `add-northbound-action-integrations`, `add-long-running-northbound-actions`, `add-per-agent-availability`
- Affected code:
  - northbound action target snapshot builders in `elixir/serviceradar_core`
  - web-ng device details LiveView/components and SRQL log query path
  - Go and Rust plugin SDK target snapshot types
  - sample northbound Wasm plugin output
  - mapper/interface ingestion where physical interface location metadata is available
