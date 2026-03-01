## 1. Implementation
- [ ] Add device delete guardrails in core (block agent-managed or active checks)
- [ ] Add device linkage read/query surface for associated resources
- [ ] Add service check soft-disable path used by device delete
- [ ] Update web-ng device detail to show linked resources and delete warnings
- [ ] Update web-ng service checks list to hide inactive checks by default with filter
- [ ] Add/confirm device tombstone reaper job and settings wiring

## 2. Tests
- [ ] Core tests for delete guardrails + service check disable
- [ ] UI tests or LiveView tests for delete confirmation + linkage display (if present)

## 3. Validation
- [ ] `openspec validate add-device-delete-guardrails --strict`
