# Design: Simplify the merged device availability rollout

## Decision 1: Converge once, in the migration and one job

An install upgrades from one of four modes. Every one ends in the state `authoritative`
had: the resolver owns the device row, the legacy writers write only
`device_availability_legacy`, transitions come from the resolver.

| Starting mode | Compatibility store | Device rows | Announce |
|---|---|---|---|
| `legacy` | rows the legacy trigger never created are seeded from `is_available` | full resolve | summary and recoveries |
| `shadow` | same (the shadow-entry seed may already have run) | full resolve | summary and recoveries |
| `cutover` | seeded at cutover; untouched | full resolve (finishes the reconciliation) | summary and recoveries |
| `authoritative` | untouched | full resolve, write-on-change (normally a no-op) | none |
| fresh install | no devices | nothing to resolve | nothing to publish |

The seed copies only devices that have no row (`ON CONFLICT DO NOTHING`). In `legacy` and
`shadow` the legacy update trigger kept every existing row equal to the legacy value, and
a row that differs from the column exists only after an unfinished rollback, where the
row is the legacy value. Copying only missing rows also means a concurrent legacy write
that created a row while the migration ran is never overwritten by the migration's older
snapshot. The seed runs before the triggers are replaced in the same transaction, so up
to the commit every legacy write is still copied by the old trigger, and after it every
legacy write goes to the store through `LegacyWrites`. A legacy-semantics Armis source
never falls back to the merged device column.

## Decision 1a: Merged Armis sources on an install that never cut over

New Armis sources default to `merged`. On an install still in `legacy` or `shadow`, such a
source pushed `availability_state`, which the mirror kept equal to the projection of
`is_available`, the legacy writers' value. Removing the mirror would silently switch it to
the merged value. The migration therefore sets those sources (no agent selected) to
`legacy`, after the compatibility store is seeded and in the same transaction, and
appends one row per source to `integration_source_availability_semantics_changes`.

On the production push path (`ArmisNorthboundPopulation`), `merged` pushes true,
false or nothing (unknown) from the mirror, and `legacy` pushes the compatibility value or
nothing when it is NULL, so every device's value and inclusion are identical. The known
non-identical conditions are recorded in the audit reason: a device whose rollback
restore had not finished at upgrade (its compatibility value is the true legacy value,
its mirror the merged one), and a device whose stage-a projection never ran (withheld
under `merged`, pushed under `legacy`). The `load_candidates/2` path COALESCEs a NULL
legacy value to false, but production runs never use it; it serves injected test
loaders.

## Decision 2: First merged decisions are reconciliations, not transitions

Without a `cutover` mode there is nothing to suppress transitions while the full resolve
runs. The resolver instead treats a device whose stored provenance is `legacy_mirror`
(the provenance the pre-merge mirror wrote) as being reconciled: its first merged
decision is written and broadcast to the UI but emits no state-feed transition and no
`device.*` event. This covers the full resolve and any inline resolution that reaches an
unreconciled device first, so the upgrade never storms. `ReconcileWorker` then publishes
the one summary and, when `transition_events` is on, the recovery events for devices the
legacy value held down and the merged value holds available.

## Decision 3: What stays, and why

- `device_availability_legacy`, its insert trigger and `LegacyWrites`: the value that
  `legacy`-semantics Armis sources push. Kept while such a source can exist.
- `availability_settings` with `transition_events` and `expiry_watermark`: a product
  setting and the expiry job's cursor.
- `Operator.transition_events/1`: the only setter of that product setting.
- The `ArmisAvailabilityPreview`: the counts an operator sees before adopting merged
  semantics. It now reads `availability_state` only, which is what it read in
  `cutover` and `authoritative`.

## Rollout window

Core is a rolling update. While an old pod still runs after the migration committed, its
availability writers and resolutions fail (the mode function is gone) and are retried or
deferred to the invalidation log; none of them writes the device column or the
compatibility store in the old way. The window ends when the old pod stops.
