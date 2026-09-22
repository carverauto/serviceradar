## 1. Implementation

- [x] 1.1 Add `IndexEvents.BulkState` to apply the service and managed state
      from the bulk editor.
- [x] 1.2 Add the modal-local target scope plus the scope-aware resolvers
      (`Selection.selected_uids_for_scope/2`,
      `Selection.validate_device_selection_for_scope/2`).
- [x] 1.3 Render the service, managed, and scope controls in the bulk modal and
      report scope changes into socket state.
- [x] 1.4 Wrap the two state updates in one `Ash.transaction/2` so either both
      commit or neither does.
- [x] 1.5 Guard the mark-unmanaged path with an explicit `is_nil(agent_id)`
      filter and report the skipped count.

## 2. Tests

- [x] 2.1 Picking a scope and cancelling leaves the selection assigns unchanged.
- [x] 2.2 An all-matching submit targets the whole result set; a selected
      submit targets only the explicit selection.
- [x] 2.3 A failure in the managed leg rolls back the service leg.
- [x] 2.4 An agent-backed device stays managed.

## 3. Validate

- [x] 3.1 `openspec validate extend-device-bulk-edit-state-and-scope --strict`
