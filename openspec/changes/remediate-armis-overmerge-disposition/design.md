## Context

The Armis over-merge collapsed distinct hardware onto one canonical device at
**ingest resolve time** (`BatchResolver` strong-match on a shared
`armis_device_id`), not through `merge_devices`. Three consequences shape the
whole design:

- **No reversible audit trail (GAP A/B/C).** `merge_audit` is only written by
  `MergeEngine.do_merge_devices` and the (disabled) `armis-dups` step; the
  ingest-time collapse wrote nothing. Even where audit rows exist they record
  only the merge-causing identifier (the shared `armis_device_id`), never the
  moved `mac` rows, and `recreate_device` reads `details['from_device_ip'/
  'from_device_hostname']` keys the merge path never writes. So
  `IdentityReconciler.unmerge_device/2` cannot rescue the MACs. Reconstruction
  must come from **current DB state** — the MAC identifier rows now piled on the
  mega-device — exactly as `agent_links.ex` does for the worker chimera.

- **The hardware-identity unit is already defined by the veto.**
  `BatchResolver.universal_macs/1` = `Mac.normalize_mac_list` (split comma-blobs
  → atomic 12-hex) → drop locally-administered MACs → `MapSet`. The veto splits
  records whose universal-MAC sets are non-empty and disjoint. Un-merge is the
  provable inverse of this, so it must reuse the identical function (extracted to
  a public `Identity.Mac` helper) or detection drifts from prevention.

- **The Armis agent is an observer, not discovered-device identity.** The
  first-party Armis runtime stamps the polling agent on every device update.
  Source policy must remove that shared value from effective identifiers;
  otherwise `agent_id` priority resolves before the disjoint-MAC veto and can
  re-collapse every reconstructed device onto the poller or survivor.

- **The ghost cleanup already froze the data.** Affected devices are tombstoned
  (`deleted_reason = 'armis_source_device_id_ghost_cleanup'`). The original
  operation estimated ~389k sole-copy `mac` rows, but a 2026-07-09 observation
  found 36,676 protected ghost tombstones owning zero MAC rows. The guards still
  freeze the tombstone population and any rows found by subsequent scoping. The
  disposition operates only on scoped tombstones that currently own a universal
  MAC; a later change removes the guards only after verification.

## Goals

- Reconstruct per-hardware devices from a mega-device's distinct universal-MAC
  groups, retaining the existing survivor UID and minting each additional split
  at a stable remediation UID derived from `{armis_id, MAC, partition}`. This
  equals the canonical Armis-only ingest hash, but does not claim UID parity for
  enriched historical updates whose lost co-occurrence included other strong
  seeds.
- Rescue any scoped orphaned sole-copy `mac` rows onto their reconstructed
  devices via the audited, TTL-resetting `DeviceIdentifier :reassign_device`
  before the TTL GC could ever reach them (reassign-before-delete). The
  2026-07-09 observation found none on the protected ghost population, so
  execution remains conditional on current scoping rather than the historical
  estimate.
- Ship dormant, dry-run by default, idempotent, fully manifest-audited, and
  provably the inverse of the ingest-time veto.
- Remove the two `armis_source_device_id_ghost_cleanup` GC guards once
  disposition is verified complete.

## Non-Goals

- Reversing the collapse via `merge_audit` / `unmerge_device` (impossible — GAP A).
- Splitting Armis collapses that have **no universal MAC anchor** (MAC-less, or
  local-administered-MAC-only). These are not splittable by hardware MAC and stay
  merged; they need a separate IP/hostname-based signal, out of scope here.
- Using `armis_device_id` alone or `source_device_id` as a split/merge key
  (`source_device_id` is not a one-to-one Armis object key).
- Re-enabling or relying on the `armis-dups` collapse step.
- Perfect multi-NIC host reconstruction where co-occurrence provenance is lost
  (see Open Questions). Per-MAC ownership is stable, so a later ingest routes
  observations back to their reconstructed owners but does not prove
  co-residency or reunite the split classes.

## Decisions

### Reconstruct from current DB state, mirroring `agent_links.ex`

The new `ArmisUnmerge` step follows the `agent_links` transaction blueprint,
keyed on distinct universal MAC instead of agent→host. The source device is the
only row that may be retained or restored. Every additional deterministic target
UID must be absent and is created fresh; an existing target is ambiguous and
fails closed for manual review. The step moves each class's `mac` rows via
`:reassign_device` and writes one `merge_audit`
`reason: "unmerge", source: "dire_remediation"` row per split to arm the per-pair
re-collapse cooldown. Before mutation it locks the source device, all source
identifier rows, the integration source, and global normalized/display MAC and
typed Armis owners, then compares the exact ownership snapshot
`{id,type,value,partition}`. The semantic identifier provenance keys are
recomputed under lock. The integration source's canonical partition must match
the planned universal-MAC partition and is also rechecked under its row lock;
hot timestamps and unrelated metadata are deliberately excluded. A short
`SHARE ROW EXCLUSIVE` barrier on both owner tables prevents
ordinary ingest DML from racing absence checks. Canonical owners use the
existing B-tree and legacy/display normalized tokens use concurrent GIN indexes;
lock acquisition is capped at 5 seconds and candidate statements at 30 seconds.
Lock/query timeout exceptions roll back the candidate and become inspectable,
nonzero report failures rather than escaping the run. A synced manifest
preflight precedes the transaction; exact prepared actions, including generated
merge-audit IDs, are appended as one batch and synced once per candidate before
database commit, and a synced committed marker follows it. Manifest files are
created exclusively and never overwrite prior rollback evidence.

### Detection = one Armis-keyed device with ≥2 distinct universal atomic MACs

The typed `armis_device_id` row is authoritative and must have exactly one owner;
optional metadata must agree with it. Live candidates additionally require
canonical `metadata.integration_type = 'armis'`, an Armis integration source,
and at least two distinct `integration_id` rows whose identifier metadata names
that same source and `integration_type = 'armis'`. The typed Armis row must carry
the same provenance. Unscoped AWX, plugin, or other-source identifiers are not
evidence. The universal filter is uppercase atomic 12-hex `mac` rows whose
2nd hex char ∉ {2,3,6,7,A,B,E,F}. `≥2` is the floor, not a scalpel — the report
surfaces the full MAC-count distribution so an operator sets an informed
threshold (genuine multi-NIC hosts also clear `≥2`; mega-devices show dozens to
hundreds). Every universal MAC row must carry the same canonical, nonblank
partition; nil/blank rows report `missing_partition`, mixed values report
`multiple_partitions`, and no default partition is synthesized. A live
candidate's integration source must carry that same canonical partition;
missing, noncanonical, or mismatched source partitions are reported instead of
planned. Detection runs only after `blob-purge` has atomized blob-hidden MACs;
the step asserts zero
non-atomic `mac` rows remain (or normalizes in Elixir via
`Mac.normalize_mac_list`). A display MAC blob that resolves to more than one
planned class reports `ambiguous_display_mac`; it cannot select a survivor from
unordered set iteration.

### New split UIDs are stable remediation identifiers

The survivor class retains the existing device UID so references and the sole
`armis_device_id` owner remain stable. For every additional class,
`Ids.generate_deterministic_device_id/1` over reconstructed
`{armis_id, class MAC, partition}` yields a distinct, reproducible `sr:` UID.
Canonical Armis-only updates hash those same seeds, but updates carrying an
agent, integration, or NetBox seed can hash differently; historical flattened
rows no longer preserve which extra seeds co-occurred with each MAC, so the
disposition makes no broader parity claim. If the existing UID already equals
one class's remediation UID, that class remains on the survivor so the plan
never emits a self-target. Re-runs converge, and later observations route to the
same reconstructed owner through the reassigned strong `mac` identifier. This
does not automatically rejoin MAC classes that belong to one multi-NIC host.

### `armis_device_id` disposition — survivor keeps it, other classes are MAC-only

To avoid creating a **new** `typed_id_on_multiple_devices` conflict (which the
Armis northbound runner now skips on), the `armis_device_id` identifier must land
on **exactly one** reconstructed device. The approved implementation first keeps
the class whose remediation-derived UID already equals the source UID, then an
unambiguous display-MAC class, and finally the lexically-lowest normalized
universal MAC. That survivor keeps the `armis_device_id`; the other reconstructed
classes are MAC-only hardware devices with no Armis identity. The rejected
alternative was to drop `armis_device_id` from all reconstructed devices and
keep it only on a tombstoned subnet-aggregate ghost.

### Ordering and guard removal

`blob-purge` → (`agent-links`) → `armis-unmerge`, before/instead-of `armis-dups`.
The two ghost-cleanup GC guards are removed in a **separate, later** step only
after a verification query confirms zero sole-copy `mac` rows remain on
`armis_source_device_id_ghost_cleanup` tombstones — never in the same change that
first ships the step.

## Risks / Trade-Offs

- **Over-splitting genuine multi-NIC hosts.** The veto guarantees *disjoint*
  universal-MAC sets ⇒ different devices, but not which MACs co-reside on one
  host, and the collapse flattened per-record provenance (interfaces were
  reassigned too). The safe default is one device per distinct universal MAC,
  which over-splits real multi-NIC hosts. That split is persistent: later ingest
  routes each MAC back to its stable reconstructed owner but does not prove the
  MACs share a host or reunite them. Live-device execution must therefore stay
  disabled unless independent co-residency evidence validates the grouping or
  the operator explicitly accepts per-MAC over-splitting (Open Questions).
- **Cap/GC erosion undercounts.** `CardinalityCaps` (mac cap 64) and prior GC
  mean a mega-device shows at most ~64 MAC rows even if it collapsed hundreds of
  hosts; some hardware classes may already have no surviving universal MAC and
  are unrecoverable. Detection therefore undercounts; the step must run inside
  the guarded window and reconcile with the sole-copy population, preserving the
  `verified` flag on reassign so caps never retire rescued rows.
- **Faker / multi-MAC-by-design confound (test + demo environments).** The
  ServiceRadar demo faker generates 33–500 MACs per device **intentionally**
  ("Armis tracks every MAC ever seen"), so on faker-heavy data distinct universal
  MAC count is NOT a reliable over-merge signal — a naive detector would
  false-positive and split legitimate faker devices. Mitigations: (a) any
  ghost-tombstoned orphan that current scoping finds with sole-copy `mac` rows is
  well-defined and faker-independent, although the 2026-07-09 observation found
  none; (b) any **live** mega-device splitting must be validated against the real
  target deployment, not the demo faker, and must exclude the faker fleet (by
  name/source) and cross-check a second over-merge signal (e.g. distinct
  `integration_id` per the June-2026 live forensics) before splitting.
  Live-device splitting is therefore gated behind the live scoping in Task 1.
- **Operator noise / partial completion.** Execute defaults to a bounded 25
  candidates per run (dry-run remains 5,000); larger explicit batches still use
  indexed owner checks and fail-closed lock/statement timeouts. A ghost whose
  retained IP is now owned by an active device fails restoration under the
  active-IP uniqueness constraint and requires manual IP resolution before
  retry; the candidate transaction remains unmodified. Reconstructed MAC-only
  devices with no other evidence may look sparse in the UI. This is strictly
  better than frozen ghost data, but the report must make the before/after shape
  explicit.
- **Rollback.** Every candidate has a durable preflight, prepared action set,
  and committed marker in the manifest (ids only). Prepared entries without a
  committed marker are conservatively reviewable after a crash. The per-split `unmerge`
  audit + standing veto prevent immediate re-collapse.

## Migration Plan

1. Extract `universal_macs`/veto grouping to public `Identity.Mac`; unit-test
   parity with `BatchResolver`, and classify the Armis polling agent as observer
   provenance before identity resolution.
2. Build `Decisions` grouping/target rules (pure) + the `ArmisUnmerge` step;
   register in the orchestrator. Ship dormant: explicit bounded dry-run remains
   available, the step is never in the default order, and execute is rejected
   before mutation until runtime signoff configuration is enabled. Live-device
   execution also requires paired device/source allowlists and rejects
   faker-backed sources.
3. DB-test on an `srql-fixtures` scratch DB: seed live + ghost-tombstoned
   mega-devices, run dry-run (assert plan), run execute (assert per-group devices
   materialized, `mac` rows reassigned + TTL reset, `unmerge` audits, manifest),
   re-run (idempotent), verify no new `typed_id_on_multiple_devices`.
4. Live dry-run against the target deployment; review counts + MAC-count
   distribution with the operator. The survivor-keeps-it `armis_device_id`
   disposition is already approved and implemented.
5. Batched execute in controlled windows; monitor identifier growth, cardinality
   anomalies, and northbound conflict counts.
6. After verification (zero sole-copy `mac` rows on ghost tombstones), a separate
   change removes the two GC guards and releases the ghost tombstones to normal
   retention.

## Open Questions

- **Multi-NIC co-residency anchor.** Is there ANY surviving per-source-record
  provenance (mapper/source payload history, OCSF device history,
  `endpoint_inventory`, interface metadata) to group co-occurring universal MACs,
  or does Phase 2 accept persistent per-distinct-MAC over-splitting? A later
  ingest does not automatically reunite the classes. Needs a look at live data.
- **Ghost-tombstoned vs. live mega-device population.** The ghost cleanup
  tombstoned a `source_device_id`-keyed ghost subset; live mega-devices
  (`deleted_at IS NULL`) with ≥2 universal MACs may also exist un-cleaned. A live
  count of each population determines whether detection targets live rows,
  ghost tombstones, or both. The 2026-07-09 observation found 36,676 protected
  ghost tombstones owning zero MAC rows; the historical ~389k estimate must not
  be used as current inventory.
- **Threshold + batch sizing.** The MAC-count distribution (live) sets the split
  threshold and per-run batch caps so a large execute cannot wedge the
  maintenance queue.
