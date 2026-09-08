## 1. Investigation
- [x] 1.1 Trace current sweep result ingestion from agent payload through core persistence and `ocsf_devices.is_available` updates.
- [x] 1.2 Identify existing latest sweep/history tables and determine whether to add a new latest-state table or extend an existing one.
- [x] 1.3 Confirm how agent display names/IDs are represented in registry and gateway state.
- [x] 1.4 Review `add-armis-northbound-availability-updates` and identify the integration point for source selection.

## 2. Data Model and Ingestion
- [x] 2.1 Add migration and Ash resource/read model for latest per-agent device availability.
- [x] 2.2 Update sweep ingestion to upsert latest availability by `(device_uid, agent_id)` with protocol/check metadata.
- [x] 2.3 Preserve or backfill existing canonical `is_available` behavior when no primary source is configured.
- [x] 2.4 Add primary availability source configuration for devices and bulk device selections.
- [x] 2.5 Update canonical `ocsf_devices.is_available` derivation to use the configured source when present.
- [x] 2.6 Add availability source profile persistence with SRQL scope, selected agent, enabled state, and deterministic precedence.
- [x] 2.7 Add an evaluator/materializer that applies profile-derived canonical source assignments while preserving per-device overrides.

## 3. SRQL and Query Surfaces
- [x] 3.1 Expose latest per-agent availability fields to SRQL device queries.
- [x] 3.2 Add filters for devices available/unavailable from a selected agent.
- [x] 3.3 Add filters for primary availability source and source freshness.
- [x] 3.4 Add tests covering per-agent availability filtering and existing `is_available` compatibility.
- [x] 3.5 Add SRQL validation and preview support for availability source profile scopes.

## 4. UI
- [x] 4.1 Add a clean per-agent availability section to device details with agent, status, checks, response time, ports, and freshness.
- [x] 4.2 Show which source drives canonical availability on device details and the device list.
- [x] 4.3 Add device/bulk action UI to select the primary availability source agent.
- [x] 4.4 Handle missing/stale per-agent availability without rendering raw JSON or ambiguous blank states.
- [x] 4.5 Add settings UI for availability source profiles, including preview, enable/disable, precedence, and deletion.
- [x] 4.6 Show profile-derived source assignment and per-device override status in device detail/list affordances.

## 5. Armis Northbound
- [x] 5.1 Add northbound availability source selection to Armis integration configuration.
- [x] 5.2 Update Armis northbound payload generation to use canonical or selected-agent availability.
- [x] 5.3 Persist and display the selected source in Armis northbound run status/summary.
- [x] 5.4 Add tests for selected-agent Armis outbound values.

## 6. Verification
- [x] 6.1 Add ingestion tests for two agents reporting different availability for the same device.
- [x] 6.2 Add UI tests or focused LiveView/component tests for the per-agent device detail section.
- [x] 6.3 Add regression tests ensuring existing single-agent installs keep current `is_available` behavior.
- [x] 6.4 Validate against demo/faker data with at least two agents and conflicting sweep outcomes.
- [x] 6.5 Run `openspec validate add-per-agent-availability --strict`.
- [x] 6.6 Add regression coverage for profile precedence, per-device overrides, stale selected-agent rows, and SRQL preview validation.
