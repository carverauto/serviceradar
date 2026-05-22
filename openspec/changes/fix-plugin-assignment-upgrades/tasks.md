## 1. Investigation
- [x] 1.1 Reproduce the `delete_assignment` LiveView crash and confirm all successful delete return shapes from `Assignments.delete/2`.
- [x] 1.2 Map current assignment replacement paths across manual assignments, policy-owned assignments, and disabled historical assignments.
- [x] 1.3 Confirm how approved package versions are ordered and how "latest" should be selected for semver and non-semver versions.

## 2. Delete Crash Fix
- [x] 2.1 Normalize `Assignments.delete/2` to return a documented shape or update all callers to handle `:ok`.
- [x] 2.2 Add regression coverage proving deleting an assignment removes it from the UI without crashing.
- [x] 2.3 Verify service-state deactivation still runs exactly once for successful deletes.

## 3. Assignment Upgrade Backend
- [x] 3.1 Add a context function for upgrading an assignment to a target package version by `plugin_id` and package ID/version.
- [x] 3.2 Preserve compatible assignment fields during upgrade: agent UID, enabled state, interval, timeout, params, permissions override, resources override, source metadata, and policy metadata where allowed.
- [x] 3.3 Reject manual upgrades of policy-owned assignments unless policy semantics explicitly allow it.
- [x] 3.4 Validate target package approval, plugin ID match, schema compatibility, and duplicate enabled assignment invariants before updating.
- [x] 3.5 Return actionable errors for duplicate assignment, incompatible schema, missing required params, not found, and forbidden policy-owned changes.

## 4. Assignment Upgrade UI
- [x] 4.1 Show current package version and latest approved version for each assignment.
- [x] 4.2 Add an "Upgrade to latest" action next to assignments with a newer approved package.
- [x] 4.3 Add a version selector for choosing a specific approved package version.
- [x] 4.4 Replace duplicate-create failures with UI guidance to upgrade/replace the existing assignment.
- [x] 4.5 Refresh the assignments list and selected package details after upgrade without requiring page reload.

## 5. Tests and Validation
- [x] 5.1 Add focused Ash/context tests for assignment upgrade success and validation failures.
- [x] 5.2 Add LiveView tests for delete, latest upgrade, specific-version upgrade, policy-owned assignment messaging, and duplicate-create guidance.
- [x] 5.3 Run `mix test` or focused test files for the changed web-ng/core modules.
- [x] 5.4 Run `mix format` for touched Elixir files.
