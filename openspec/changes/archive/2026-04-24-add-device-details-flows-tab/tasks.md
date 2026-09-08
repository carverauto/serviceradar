## 1. Specification
- [x] 1.1 Confirm `device_id` scope contract for flows: exporter mapping (`netflow_exporter_cache.device_uid`) plus endpoint IP/alias mapping.
- [x] 1.2 Confirm existing flow details UI contract to reuse from device details row selection.

## 2. SRQL
- [x] 2.1 Add `device_id` filter support for `in:flows`.
- [x] 2.2 Implement `device_id` filter semantics:
- [x] 2.2.1 Exporter flows match via `sampler_address` -> `netflow_exporter_cache.device_uid`.
- [x] 2.2.2 Endpoint flows match when `src_endpoint_ip` or `dst_endpoint_ip` equals device primary/alias IPs.
- [x] 2.3 Ensure device-scoped flow queries use deterministic ordering for stable pagination.
- [x] 2.4 Add SRQL parser/translator tests for device-scoped flow queries.

## 3. Web-NG Device Details
- [x] 3.1 Add `Flows` tab state and tab rendering in device details.
- [x] 3.2 Query SRQL for device-scoped flows and show tab only when rows exist.
- [x] 3.3 Render paginated flow rows in the device details `Flows` tab.
- [x] 3.4 Wire row click to reuse existing flow details UI.
- [x] 3.5 Add LiveView tests for tab visibility, pagination, and row drill-in.

## 4. Validation
- [x] 4.1 Run `openspec validate add-device-details-flows-tab --strict`.
- [ ] 4.2 Run focused test coverage for web-ng device details and SRQL flow parsing/translation.
