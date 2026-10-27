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
the one summary whenever live devices exist (including zero differences) and, when
`transition_events` is on, the recovery events for devices the
legacy value held down and the merged value holds available.

The internal `availability_settings.converged_at` timestamp is a one-time upgrade
convergence marker, not an operator mode. Nothing user-facing sets or reads it. Before
dropping the mode function, the migration sets it for authoritative deployments and for
installs with no device rows. For other upgrades it stays NULL until the full resolve
and rollup rebuild succeed. Every resolving transaction reads it once; while NULL,
devices with NULL provenance are read as the legacy mirror's projection of
`is_available`. Thus ordinary ingestion, resolver and expiry workers, and reconciliation
all preserve unknown's last boolean and suppress the initial transition. Once set, new
devices use normal first-decision semantics. At completion, an existing unhealthy
`availability_cutover_readiness` health check is recorded healthy through HealthTracker,
retaining its history; absent and already healthy checks receive no new record.

## Decision 3: What stays, and why

- `device_availability_legacy`, its insert trigger and `LegacyWrites`: the value that
  `legacy`-semantics Armis sources push. Kept while such a source can exist.
- `availability_settings` with `transition_events`, `expiry_watermark` and `converged_at`:
  a product setting, the expiry job's cursor and the internal upgrade marker.
- `Operator.transition_events/1`: the only setter of that product setting.
- The `ArmisAvailabilityPreview`: the counts an operator sees before adopting merged
  semantics. It now reads `availability_state` only, which is what it read in
  `cutover` and `authoritative`.

## Rollout window

Core is a rolling update. After the migration commits, old-pod availability paths
that call `availability_mode()` fail because the function is gone; their work is
retried or deferred to the invalidation log. This does not stop every in-flight write.
An old core pod already executing a stage-a
`ServiceRadar.Inventory.Availability.CaptureBackfillWorker` job can continue its page
transactions after convergence, rewriting `availability_state` and provenance and
seeding `consecutive_down` on unavailable per-agent ledger rows still at 0. An executing
`ServiceRadar.Inventory.Availability.CutoverWorker` restore (`hold_legacy` rollback)
can also commit a page that passed its mode check before the migration, rewriting
availability state and provenance after convergence.

This residual is accepted because these jobs run only immediately after stage a ships
or during a `hold_legacy` rollback. They do not affect the Armis legacy table or its
northbound pushes. Operators confirm that neither job is pending or executing on the
old release before upgrading, using the checks in
`docs/merged-device-availability.md`, and wait for any such jobs to finish. No migration
drain guard or deployment-strategy change is introduced.
