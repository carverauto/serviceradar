# Change: Device fact retract API

## Why

External applications write device facts to ServiceRadar via
`PATCH /api/devices/:uid/metadata` with `{"facts": {"<key>": <value>}}`.
Once written, a fact cannot be removed: writing `null` stores a JSON null
rather than removing the key, and provenance is left behind. An application
that wrote a fact that turned out to be wrong, or can no longer determine a
value, needs to retract it cleanly so the metadata stays accurate and
composite checks do not act on stale signals.

## What Changes

- Add `DELETE /api/devices/:uid/metadata/facts/:key` to remove a single
  fact key from `metadata` and its entry from `metadata.__fact_provenance`
  atomically in one SQL statement, matching the approach used by the write path.
- Add a `Device.remove_facts` Ash action backed by a new
  `RemoveDeviceFacts` change module, mirroring `write_facts` /
  `MergeDeviceFacts` in structure and authorization.
- **Caller-owns-provenance rule**: a caller may only remove a fact whose
  provenance source matches the caller's own source identity (the same
  identity recorded when the fact was written). A fact written by a
  different integration cannot be removed through this path.
- **Non-fact guard**: only keys present in `__fact_provenance` may be
  removed. Integration-owned metadata not written via the fact API is
  never touched. Removing a key not in provenance is a no-op (idempotent).
- **Reserved-key guard**: `__fact_provenance` and any key that does not
  match the fact key pattern are rejected immediately.
- Same `devices.facts.write` permission as the write path.

## API shape rationale

`DELETE /api/devices/:uid/metadata/facts/:key` was chosen over extending
the existing `PATCH` body with a `remove_facts` field because:

1. DELETE is the correct HTTP verb for a removal; the operation is
   inherently idempotent (DELETE is idempotent by spec).
2. Addressing the specific key in the URL makes the resource being operated
   on explicit, consistent with REST conventions.
3. A caller removing multiple keys makes sequential DELETE requests, which
   mirrors how they write (one PATCH call per key-set). The underlying Ash
   action accepts a list, so a batch route can be added later without
   changing the action layer.

## Impact

- Affected spec: `device-inventory`
- Affected code: `serviceradar_core` change module and Device action;
  `web-ng` controller and router
- **BREAKING**: none — existing write behavior is unchanged; new endpoint only
