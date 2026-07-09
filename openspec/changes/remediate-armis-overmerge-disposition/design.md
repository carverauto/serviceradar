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

- **The ghost cleanup already froze the data.** Affected devices are tombstoned
  (`deleted_reason = 'armis_source_device_id_ghost_cleanup'`) and their ~389k
  sole-copy `mac` rows are guarded from GC/retention. Disposition operates on
  that frozen population and, on completion, removes the guards.

## Goals

- Reconstruct per-hardware devices from a mega-device's distinct universal-MAC
  groups, minting the same deterministic UID a veto-gated ingest would produce
  (`Ids.generate_deterministic_device_id/1`).
- Rescue the ~389k orphaned sole-copy `mac` rows onto their reconstructed
  devices via the audited, TTL-resetting `DeviceIdentifier :reassign_device`
  before the TTL GC could ever reach them (reassign-before-delete).
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
  (see Open Questions; the safe default over-splits and is reconciled by the
  standing veto on next ingest).

## Decisions

### Reconstruct from current DB state, mirroring `agent_links.ex`

The new `ArmisUnmerge` step copies the `agent_links` blueprint, keyed on distinct
universal MAC instead of agent→host: for each mega-device, derive the target
groups, then per group choose a target device in order **adopt-live /
restore-tombstone (`recreate_device`) / create-fresh**, move that group's `mac`
identifier rows via `:reassign_device`, and write one `merge_audit`
`reason: "unmerge", source: "dire_remediation"` row per split to arm the per-pair
re-collapse cooldown. All within an `Ash.transaction`; `Manifest.record` every
device restore/create and every identifier reassignment (ids only).

### Detection = one Armis-keyed device with ≥2 distinct universal atomic MACs

Grouping key copied verbatim from `armis_dups` (`COALESCE(metadata->>'armis_device_id',
armis_device_id identifier)`); universal filter = atomic 12-hex `mac` rows whose
2nd hex char ∉ {2,3,6,7,A,B,E,F}. `≥2` is the floor, not a scalpel — the report
surfaces the full MAC-count distribution so an operator sets an informed
threshold (genuine multi-NIC hosts also clear `≥2`; mega-devices show dozens to
hundreds). Detection runs only after `blob-purge` has atomized blob-hidden MACs;
the step asserts zero non-atomic `mac` rows remain (or normalizes in Elixir via
`Mac.normalize_mac_list`).

### Target UID = the UID the veto would have minted

Per group, `Ids.generate_deterministic_device_id/1` over a reconstructed
`{armis_id, class MAC, partition}` yields a distinct, reproducible `sr:` UID —
the same one a fresh veto-gated ingest of that hardware resolves to by strong
`:mac` match. This makes the step idempotent (re-runs converge) and self-healing
with live ingest.

### `armis_device_id` disposition — survivor keeps it, other classes are MAC-only

To avoid creating a **new** `typed_id_on_multiple_devices` conflict (which the
Armis northbound runner now skips on), the `armis_device_id` identifier must land
on **exactly one** reconstructed device. Recommended default (mirroring
`armis_dups`' protected-owner ranking): the survivor class is the one carrying
the device's genuine/agent-bound MAC (or, absent one, the most-recently-seen
universal MAC); it keeps the `armis_device_id`. The other reconstructed classes
are MAC-only hardware devices with no Armis identity. **This is the primary
decision needing operator confirmation** (see Open Questions) — the alternative
(drop `armis_device_id` from all split devices, keeping it only on the
tombstoned subnet-aggregate ghost) is also defensible if Armis genuinely tracks
the subnet, not the host.

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
  which over-splits real multi-NIC hosts. Mitigation: this is self-correcting —
  a subsequent real ingest carrying multiple NICs on one record shares a
  universal MAC with a reconstructed device and re-consolidates via the standing
  veto/`:mac` match; and the step can consume any surviving co-occurrence signal
  if one is found (Open Questions).
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
  false-positive and split legitimate faker devices. Mitigations: (a) the primary,
  surgical target is the **ghost-tombstoned orphan population** (the sole-copy
  `mac` rows on `armis_source_device_id_ghost_cleanup` tombstones), reassigned to
  their true live owners — this is well-defined and faker-independent; (b) any
  **live** mega-device splitting must be validated against the real target
  deployment, not the demo faker, and must exclude the faker fleet (by name/source)
  and cross-check a second over-merge signal (e.g. distinct `integration_id` per
  the June-2026 live forensics) before splitting. Live-device splitting is
  therefore gated behind the live scoping in Task 1.
- **Operator noise / partial completion.** Reconstructed MAC-only devices with
  no other evidence may look sparse in the UI. This is strictly better than
  frozen ghost data, but the report must make the before/after shape explicit.
- **Rollback.** Every restore/create/reassign is manifest-recorded (ids only);
  an operator can target-reverse any single action. The per-split `unmerge`
  audit + standing veto prevent immediate re-collapse.

## Migration Plan

1. Extract `universal_macs`/veto grouping to public `Identity.Mac`; unit-test
   parity with `BatchResolver`.
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
   distribution + the `armis_device_id` disposition decision with the operator.
5. Batched execute in controlled windows; monitor identifier growth, cardinality
   anomalies, and northbound conflict counts.
6. After verification (zero sole-copy `mac` rows on ghost tombstones), a separate
   change removes the two GC guards and releases the ghost tombstones to normal
   retention.

## Open Questions

- **Multi-NIC co-residency anchor.** Is there ANY surviving per-source-record
  provenance (mapper/source payload history, OCSF device history,
  `endpoint_inventory`, interface metadata) to group co-occurring universal MACs,
  or does Phase 2 accept per-distinct-MAC over-splitting (reconciled by the veto
  on next ingest)? Needs a look at live data.
- **`armis_device_id` disposition.** Survivor-keeps-it (recommended) vs.
  drop-from-all-split-devices (armis tracks the subnet aggregate). Depends on
  what an `armis_device_id` semantically represents for this deployment — an
  operator/Armis-domain decision, confirmable against the export.
- **Ghost-tombstoned vs. live mega-device population.** The ghost cleanup
  tombstoned a `source_device_id`-keyed ghost subset; live mega-devices
  (`deleted_at IS NULL`) with ≥2 universal MACs may also exist un-cleaned. A live
  count of each population determines whether detection targets live rows,
  ghost tombstones, or both, and how much of the ~389k is reachable.
- **Threshold + batch sizing.** The MAC-count distribution (live) sets the split
  threshold and per-run batch caps so a large execute cannot wedge the
  maintenance queue.
