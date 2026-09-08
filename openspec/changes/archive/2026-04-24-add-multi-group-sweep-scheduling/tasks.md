## 1. Core Sweep Config Output
- [ ] 1.1 Confirm sweep compiler emits group schedules and settings per group in the `groups` array.
- [ ] 1.2 Add/adjust tests to ensure multiple sweep groups are preserved (no merging) in the compiled payload.

## 2. Agent Parsing & Scheduling
- [ ] 2.1 Update sweep config parsing to retain per-group configs (no flattening).
- [ ] 2.2 Implement per-group scheduling/execution (one sweeper per group or equivalent scheduler).
- [ ] 2.3 Ensure results carry the correct `sweep_group_id` and execution context per group.

## 3. Validation
- [ ] 3.1 Add tests for multi-group scheduling (distinct intervals, no merge).
- [ ] 3.2 Verify a demo agent runs two groups with different intervals without increasing scan frequency beyond configured intervals.
