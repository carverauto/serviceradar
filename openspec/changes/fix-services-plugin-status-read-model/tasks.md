## 1. Investigation
- [x] 1.1 Capture current `/services` data flow from agent plugin execution through gateway, `ResultsRouter`, `PluginResultIngestor`, `ServiceStateRegistry`, and LiveView rendering.
- [x] 1.2 Identify all active first-party plugin assignments in demo and classify failures as config missing, host-function/network, runtime panic, or ingestion/read-model stale.
- [x] 1.3 Confirm whether current `platform.service_state` rows are missing, stale, or overwritten for the failing examples.

## 2. Current-State Read Model
- [x] 2.1 Update plugin result ingestion so every accepted plugin result writes the historical `service_status` row and upserts the corresponding `service_state` row.
- [x] 2.2 Make assignment reconciliation monotonic so placeholders cannot overwrite newer real results.
- [x] 2.3 Add an idempotent repair path that rebuilds active plugin service states from recent `service_status` rows.
- [x] 2.4 Collapse stale active plugin service rows that share the same logical service identity but were written with transient gateway IDs.
- [x] 2.5 Ensure `/services` initial render reads active plugin state from Postgres and does not wait for the next status check.

## 3. Plugin Execution Repair
- [ ] 3.1 Add generated-config assertions for AWX/AAP assignments, including `base_url`, token/credential material, timeout, TLS policy, and approved HTTP permissions.
- [x] 3.2 Add generated-config assertions for Proxmox inventory assignments, including controller base URL, credential broker/token material, target set, timeout, TLS policy, and approved HTTP permissions.
- [x] 3.3 Reproduce and fix the Proxmox Wasm `encoding/json`/TinyGo trap with a minimal runtime fixture.
- [ ] 3.4 Publish/import the fixed Proxmox Wasm artifact into demo and verify the active assignment no longer runs the old artifact.
- [ ] 3.5 Verify OTX and Dusk host-function failures distinguish external connectivity or allowlist denial from agent runtime bugs.
- [x] 3.6 Verify UniFi Protect scheduled and streaming assignments do not interfere with each other and report current state independently.

## 4. Plugin Package Invariants
- [x] 4.1 Enforce one approved package version per plugin ID in code and database schema.
- [x] 4.2 Revoke superseded package versions and disable assignments that still point at superseded packages.
- [x] 4.3 Repair existing demo rows so stale package versions and assignments are no longer active.
- [x] 4.4 Enforce one enabled assignment per agent/plugin ID and exclude disabled assignments from generated agent config.

## 5. UI and Diagnostics
- [x] 5.1 Keep failures sorted first and newest-first within each status class.
- [x] 5.2 Preserve detailed plugin failure messages for operator diagnostics while keeping cards compact.
- [ ] 5.3 Ensure the service detail link resolves from a `service_state` row to the latest historical `service_status` details.

## 6. Tests and Validation
- [x] 6.1 Add Ash/resource tests for `ServiceStateRegistry` placeholder protection and history-to-state repair.
- [ ] 6.2 Add `PluginResultIngestor` tests proving current-state upsert happens for OK and failure plugin results.
- [ ] 6.3 Add LiveView tests proving `/services` reload renders persisted OK/FAIL states without waiting for PubSub.
- [x] 6.4 Add Go plugin runtime tests for first-party plugin config fixtures and Proxmox panic regression.
- [x] 6.5 Add package approval tests for single-approved-version enforcement.
- [x] 6.6 Run focused Elixir and Go tests for touched modules.
