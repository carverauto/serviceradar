## 1. Investigation
- [ ] 1.1 Reproduce the `delete_assignment` LiveView crash and confirm all successful delete return shapes from `Assignments.delete/2`.
- [ ] 1.2 Map current assignment replacement paths across manual assignments, policy-owned assignments, and disabled historical assignments.
- [ ] 1.3 Confirm how approved package versions are ordered and how "latest" should be selected for semver and non-semver versions.

## 2. Delete Crash Fix
- [ ] 2.1 Normalize `Assignments.delete/2` to return a documented shape or update all callers to handle `:ok`.
- [ ] 2.2 Add regression coverage proving deleting an assignment removes it from the UI without crashing.
- [ ] 2.3 Verify service-state deactivation still runs exactly once for successful deletes.

## 3. Assignment Upgrade Backend
- [ ] 3.1 Add a context function for upgrading an assignment to a target package version by `plugin_id` and package ID/version.
- [ ] 3.2 Preserve compatible assignment fields during upgrade: agent UID, enabled state, interval, timeout, params, permissions override, resources override, source metadata, and policy metadata where allowed.
- [ ] 3.3 Reject manual upgrades of policy-owned assignments unless policy semantics explicitly allow it.
- [ ] 3.4 Validate target package approval, plugin ID match, schema compatibility, and duplicate enabled assignment invariants before updating.
- [ ] 3.5 Return actionable errors for duplicate assignment, incompatible schema, missing required params, not found, and forbidden policy-owned changes.

## 4. Assignment Upgrade UI
- [ ] 4.1 Show current package version and latest approved version for each assignment.
- [ ] 4.2 Add an "Upgrade to latest" action next to assignments with a newer approved package.
- [ ] 4.3 Add a version selector for choosing a specific approved package version.
- [ ] 4.4 Replace duplicate-create failures with UI guidance to upgrade/replace the existing assignment.
- [ ] 4.5 Refresh the assignments list and selected package details after upgrade without requiring page reload.

## 5. Tests and Validation
- [ ] 5.1 Add focused Ash/context tests for assignment upgrade success and validation failures.
- [ ] 5.2 Add LiveView tests for delete, latest upgrade, specific-version upgrade, policy-owned assignment messaging, and duplicate-create guidance.
- [ ] 5.3 Run `mix test` or focused test files for the changed web-ng/core modules.
- [ ] 5.4 Run `mix format` for touched Elixir files.
