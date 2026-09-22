# Change: Extend the device bulk editor with service and managed state plus an explicit target scope

## Why

The device list bulk editor could only apply tags, and only to the currently
selected page. Operators need to mark devices in service / out of service and
managed / unmanaged, and to apply a change to the entire SRQL result set
driving the page rather than the visible page (GitHub #4543).

## What Changes

- The device bulk editor SHALL also apply a service state (in service / out of
  service) and a managed state (managed / unmanaged).
- "Out of service" is `is_active = false`, the same flag
  `device_out_of_service?/1` reads. There is no separate out-of-service column,
  and the agent-owned `is_available` bit is not written.
- The operator SHALL choose an explicit target scope: only the current
  selection, or every device matching the SRQL query driving the page. The
  existing 10,000-device cap and the unknown-selection-size guard are preserved.
- A single scope control SHALL govern both the tag submit and the state submit.
- Cancelling the modal SHALL NOT change the selection or the scope.
- Agent-backed devices (`agent_id` present) MUST NOT be marked unmanaged; the
  operator SHALL be told how many were skipped for that reason.
- The service and managed changes of one submit SHALL apply in one transaction,
  so a failure of the second rolls back the first.

## Impact

- Affected specs: `device-inventory` (owner), `sweep-jobs`
- Affected code: `elixir/web-ng` device LiveView
  (`IndexEvents.BulkState`, `IndexEvents.Selection`, `IndexView.BulkModals`) and
  `ServiceRadar.Inventory.Device`. No schema migration.
