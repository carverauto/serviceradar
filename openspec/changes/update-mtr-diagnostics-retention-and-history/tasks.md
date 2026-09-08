## 1. Data And Retention
- [x] 1.1 Add or extend a platform-schema Ash settings resource for MTR diagnostics retention and history defaults.
- [x] 1.2 Add an Elixir migration to create or alter the settings table and seed existing installs with the current default retention.
- [x] 1.3 Implement an idempotent MTR retention policy reconciler for `platform.mtr_traces` and `platform.mtr_hops`.
- [x] 1.4 Add startup or settings-save reconciliation so Timescale policy state matches the persisted MTR setting.
- [x] 1.5 Add Helm and Docker Compose install-time default retention configuration.

## 2. SRQL And Query APIs
- [x] 2.1 Add explicit SRQL time-range support for `in:mtr_traces` queries, including relative and absolute ranges.
- [x] 2.2 Ensure MTR query ordering is stable for pagination with a deterministic tie-breaker.
- [x] 2.3 Add query helpers for device-scoped retained MTR history, target history, hop detail, and comparison views.
- [x] 2.4 Add tests covering MTR SRQL date/time filters and paginated retained history.

## 3. Product Experience
- [x] 3.1 Replace fixed recent-only device MTR loading with paginated retained history controls.
- [x] 3.2 Add first-party MTR visual diagnostics for latency/loss trends, path changes, hop heatmaps, reachability, and source-agent comparison.
- [x] 3.3 Show retention status, configured retention days, and estimated available poll history in MTR diagnostics surfaces.
- [x] 3.4 Add warning/confirmation behavior when lowering MTR retention from the UI.
- [x] 3.5 Preserve trace and hop drill-down from every summary or visualization.

## 4. Validation
- [x] 4.1 Run focused Elixir tests for MTR diagnostics UI/query helpers and retention settings.
- [x] 4.2 Run SRQL tests for MTR time filters.
- [x] 4.3 Validate Timescale retention policy changes against a local or fixture CNPG database.
- [x] 4.4 Capture desktop and mobile screenshots of the updated MTR diagnostics and device detail flows.
