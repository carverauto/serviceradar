## 1. Investigation
- [ ] 1.1 Trace current sweep result ingestion from agent payload through core persistence and `ocsf_devices.is_available` updates.
- [ ] 1.2 Identify existing latest sweep/history tables and determine whether to add a new latest-state table or extend an existing one.
- [ ] 1.3 Confirm how agent display names/IDs are represented in registry and gateway state.
- [ ] 1.4 Review `add-armis-northbound-availability-updates` and identify the integration point for source selection.

## 2. Data Model and Ingestion
- [ ] 2.1 Add migration and Ash resource/read model for latest per-agent device availability.
- [ ] 2.2 Update sweep ingestion to upsert latest availability by `(device_uid, agent_id)` with protocol/check metadata.
- [ ] 2.3 Preserve or backfill existing canonical `is_available` behavior when no primary source is configured.
- [ ] 2.4 Add primary availability source configuration for devices and bulk device selections.
- [ ] 2.5 Update canonical `ocsf_devices.is_available` derivation to use the configured source when present.

## 3. SRQL and Query Surfaces
- [ ] 3.1 Expose latest per-agent availability fields to SRQL device queries.
- [ ] 3.2 Add filters for devices available/unavailable from a selected agent.
- [ ] 3.3 Add filters for primary availability source and source freshness.
- [ ] 3.4 Add tests covering per-agent availability filtering and existing `is_available` compatibility.

## 4. UI
- [ ] 4.1 Add a clean per-agent availability section to device details with agent, status, checks, response time, ports, and freshness.
- [ ] 4.2 Show which source drives canonical availability on device details and the device list.
- [ ] 4.3 Add device/bulk action UI to select the primary availability source agent.
- [ ] 4.4 Handle missing/stale per-agent availability without rendering raw JSON or ambiguous blank states.

## 5. Armis Northbound
- [ ] 5.1 Add northbound availability source selection to Armis integration configuration.
- [ ] 5.2 Update Armis northbound payload generation to use canonical or selected-agent availability.
- [ ] 5.3 Persist and display the selected source in Armis northbound run status/summary.
- [ ] 5.4 Add tests for selected-agent Armis outbound values.

## 6. Verification
- [ ] 6.1 Add ingestion tests for two agents reporting different availability for the same device.
- [ ] 6.2 Add UI tests or focused LiveView/component tests for the per-agent device detail section.
- [ ] 6.3 Add regression tests ensuring existing single-agent installs keep current `is_available` behavior.
- [ ] 6.4 Validate against demo/faker data with at least two agents and conflicting sweep outcomes.
- [ ] 6.5 Run `openspec validate add-per-agent-availability --strict`.
