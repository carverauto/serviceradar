# Persistent topology bitmap identities

`FleetIdentity` owns identity allocation. Canonical devices, including canonical
endpoint devices, share `platform.device_fleet_ordinals`. A layout row,
aggregate glyph or edge clip is never an inventory identity.
`fleet_dictionary_epochs` stores the durable inventory epoch; index processes
have separate, volatile epochs.

The sequence and column support `1..4294967295`, reserve zero and never cycle.
Migration preserves existing values, gaps and tombstones. Routine lookups of an
assigned UID do not consume sequence values. Allocation locks the canonical
device row, so concurrent allocation and identity transitions serialize. At
capacity, new allocation fails while existing IDs remain readable. Operational
capacity checks read each sequence's `last_value` and compare it with its declared
maximum; callers must not invoke `nextval` to measure capacity.

The endpoint inventory API delegates to this owner and retains its historical
service-component exclusion. The shared dictionary itself covers every canonical
inventory device. Its live membership follows `deleted_at`, `deleted_reason`
and `is_active`; availability is a separate facet.

## Write coverage

| Writer | Identity boundary |
| --- | --- |
| `Device` create/update/soft-delete/restore actions | Canonical table lifecycle triggers |
| `Inventory.Sync.DeviceWrites` raw bulk upserts | Same database triggers; merged/retained records remain excluded by the existing conflict update |
| `Edge.AgentGatewaySync` | Gateway actions and retained/merged identity checks |
| Sweep, mapper, source-retirement and remediation writes | Same lifecycle triggers when deletion/active state changes |
| `Identity.MergeEngine`, `Identity.Reassignments`, `EndpointInventoryMoves` | Existing device transaction locks; survivor ordinal stays, losing ordinal becomes tombstoned |
| `DeviceCleanupWorker` | Permanent dictionaries are excluded from the recursive delete plan |

A stale event cannot restore a merged-away device through the ordinary restore
validation. An explicit operator restore or unmerge uses the existing
`allow_retained` argument and reuses the original ordinal.

## Backfill and retention

`FleetIdentity.backfill_devices/2` reconciles keyset pages of at most 500 source rows. The caller persists the returned cursor and
continues until `done?`; restarting a scan is safe. Allocation does not build a
second index or run a fleet-wide startup transaction. Dirty delivery and periodic
reconciliation remain responsible for changes behind an earlier cursor.

After the configured deletion retention period, an allocated device keeps only
its canonical identity tombstone, deletion lineage and legacy merge pointers.
Mutable inventory fields and ordinary dependent records are removed. The
`identity_purged_at` marker and partial keyset index prevent those tombstones from
repeatedly consuming cleanup batches. A legitimate restore clears the marker.
Existing automation audit/quarantine references retain their prior full-record
skip policy. Approved AWX membership links are quarantined and detached when
mutable canonical inventory is purged, so a subsequent restore inherits no old
approval.

Schema rollback retains dictionary assignments, epoch, widened storage and purge
markers. It disables lifecycle triggers while permanent DELETE/TRUNCATE guards remain,
so older cleanup code cannot erase assignments. A subsequent migration reuses the same
identity data. Never delete dictionary rows or renumber IDs as a rollback step.
Back up the dictionaries and epoch with canonical inventory.
