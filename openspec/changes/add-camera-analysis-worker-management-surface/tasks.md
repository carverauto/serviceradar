## 1. Management API
- [ ] 1.1 Add authenticated API endpoints to list and inspect camera analysis workers.
- [ ] 1.2 Support registering, updating, enabling, and disabling workers through the management surface.
- [ ] 1.3 Expose worker identity, adapter, endpoint, capabilities, health state, and recent failover-relevant metadata in the API response.

## 2. Operator Surface
- [ ] 2.1 Add an operator-facing `web-ng` surface for camera analysis worker inspection.
- [ ] 2.2 Show worker health, capabilities, enabled state, and recent failure/failover-relevant metadata.
- [ ] 2.3 Keep the management surface aligned with the runtime registry model rather than duplicating state.

## 3. Verification
- [ ] 3.1 Add focused controller/LiveView tests for management and inspection.
- [ ] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-management-surface --strict`.
