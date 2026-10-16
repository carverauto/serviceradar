# ServiceRadar Atlas persistent bitmap identities

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

## Rollout configuration

Bitmap filtering is disabled by default. Helm deployments enable it with
`webNg.topologyBitmapEnabled: true` while `webNg.godViewEnabled` is also enabled.
`webNg.topologyBitmapTagKeys` is a list of literal `Device.tags` keys, for example
`[role, environment]`. The list permits at most 25 unique UTF-8 keys, each 1 to
60 bytes. The filter builder receives this allowlist from `bitmap.query` in the
topology manifest; it never enumerates fleet tag values. `Inventory VLAN` means
the device inventory VLAN, not every VLAN carried by its interfaces.

Non-Helm releases use `SERVICERADAR_TOPOLOGY_BITMAP_ENABLED=true` and
`SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS='["role","environment"]'`, together with
`SERVICERADAR_GOD_VIEW_ENABLED=true`. The tag setting is a bounded JSON array so
literal commas in a key are preserved. Invalid tag configuration prevents
startup with an explicit configuration error. Helm renders both variables from
the first-class values and ignores competing `extraEnv`/`extraEnvValueFrom`
entries. Roll the web release after changing these deployment settings.

Readiness follows initial canonical identity backfill and a complete bounded
inventory scan. Disabling bitmap filtering closes the local index and its work;
the base topology remains available. Current query membership is re-evaluated
on every page, so restart pagination to see newly matching identities below an
existing cursor.

## Address and Prefix Tag selection

Numeric IP/CIDR filters select devices by any current assigned address: the
canonical primary IP, active `ip` and `interface_ip` aliases, discovered interface
addresses, and existing virtual NIC addresses. Operationally down interfaces
remain eligible; retired/deleted/inactive devices do not. Historical identifiers
without a current corroborating source are excluded. Assigned CIDR strings retain
their host address, scoped IPv6 addresses discard the zone, and IPv4-mapped IPv6
addresses use the IPv4 identity. Query CIDRs mask host bits and never resolve DNS.
A shared address selects every owning device; it never merges identities.

Scalar fields and complete address replacements publish in one native revision
after a repeatable-read source transaction. Address cursors transfer at most 500
typed associations per fetch and the transaction has an eight-second deadline.
An interface array above 4096 entries or a native address-capacity failure makes
IP selection explicitly unavailable instead of returning a partial match. A
failed source transaction retains the prior accepted revision for retry. Array
cardinality checks can still require PostgreSQL to decompress stored
values; statement and transaction deadlines bound that database work. The
unavailable state persists across later batches until the local index is rebuilt.

Configured device tag prefixes are literal, case-sensitive text prefixes. A
paired key/value predicate must match the same configured key. Missing values do
not match prefixes merely because exact filtering represents them as `unknown`.

Named Prefix Tags use existing local prefix snapshots and preserve their full
matching-chain semantics: a label selects the union of prefixes carrying that
label, including broader prefixes when a more specific prefix also matches.
Discovery is limited to 32 local sources and 50 labels per page. Its cursor binds
the source, current authority and last label, so each page sees current membership.
Each query captures each source once and rechecks the captured versions before
delivery. No query makes a core RPC or enumerates fleet addresses in Elixir.
Compiled label selectors share a whole-query budget of 4096 ranges and 256 KiB;
overflow fails explicitly. Feature catalogs are prepared by the existing background
worker, have a global 4 MiB additional native-memory cap, and are released when
bitmap filtering is disabled. Catalog unavailability does not disable scalar
filters or the ordinary Prefix Tags lookup service.
