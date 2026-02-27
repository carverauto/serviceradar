# Change: Add Flows Tab To Device Details

## Why
Issue #2771 requests device-centric NetFlow investigation directly from the device details page. Today, operators must leave the device context and manually filter on the standalone flows view, which slows troubleshooting and increases query errors.

## What Changes
- Add a conditional `Flows` tab to web-ng device details.
- Populate the tab from SRQL `in:flows device_id:"<device_uid>"` queries scoped to the selected device.
- Define `in:flows device_id` mapping semantics:
  - Match exporter-owned flows where `ocsf_network_activity.sampler_address` resolves through `platform.netflow_exporter_cache.device_uid`.
  - Match endpoint flows where `src_endpoint_ip` or `dst_endpoint_ip` equals the device primary IP or active IP aliases.
- Render a paginated flows table in the device details tab.
- Reuse existing flow details UI when a flow row is selected.
- Add SRQL requirements for deterministic ordering for device-scoped flow pagination.

## Impact
- Affected specs: `build-web-ui`, `srql`
- Affected code (expected):
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex` (or shared flow detail component wiring)
  - SRQL flow query modules in `rust/srql/src/query/flows.rs` for `device_id` filter support and deterministic ordering
- Breaking changes: None intended (additive UI behavior)
