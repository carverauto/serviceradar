# Merged device availability: cutover runbook

Stage c of OpenSpec change `add-merged-device-availability` (GitHub #5789). The cutover
makes the merged resolver the only writer of `ocsf_devices.availability_state` and
`is_available`, so the device badge, the device order, the Available and Unknown counts,
SRQL `availability:` and Armis canonical sources in `merged` semantics all read one value.

This is an operator step. Nothing switches automatically on deploy.

## Modes

| Mode | Who writes `is_available` | `availability_state` | Transition events |
|---|---|---|---|
| `legacy` | legacy writers | mirror of `is_available` | legacy publishers |
| `shadow` | legacy writers | mirror; the resolver writes `device_availability_shadow` | legacy publishers |
| `cutover` | resolver (legacy writers write `device_availability_legacy` only) | resolver | none per device |
| `authoritative` | resolver | resolver | resolver, through the outbox |

`cutover` lasts while the reconciliation job re-resolves every device; the job moves the
mode to `authoritative` itself.

## Preconditions

1. The release with migration `20261024120000_add_merged_availability_cutover` is
   deployed on every core node, and the deployment is in `shadow`.
2. The divergence report has been reviewed (task 2.6).
3. Decide whether the deployment emits `device.available` / `device.unavailable`
   events. The migration turned `transition_events` on only if a sweep group already
   emitted them. A transition decided by a sweep group's agents is emitted only when that
   group has `emit_availability_events`.
4. Every Armis northbound source without a selected agent stays in `legacy` semantics
   and keeps pushing the legacy value. Review each source's preview before adopting
   `merged`; nothing is adopted by the cutover.

## Commands

Set the target once. For the demo deployment:

```bash
CORE='kubectl --context carverauto -n demo exec deploy/serviceradar-core -c core-elx -- /app/bin/serviceradar_core_elx'
```

### Check the state

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.status()'
```

Expect `mode: "shadow"`, an `invalidation_backlog` near 0 and no `cutover_jobs`.

Optionally set transition events before switching:

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.transition_events(false)'
```

### Switch

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.switch("cutover")'
```

The switch takes the mode-switch lock exclusively, which drains the legacy writers,
seeds `device_availability_legacy` from every device's `is_available` and enqueues the
reconciliation. `{:error, :mode_switch_busy}` means a writer held the lock for the whole
retry window (about 10 s); run the switch again.

### Verify

Each check has a failure branch; do not report success until all pass.

1. The reconciliation finished:

   ```bash
   $CORE rpc 'ServiceRadar.Inventory.Availability.Operator.status()'
   ```

   Pass: `mode: "authoritative"` and `cutover_jobs` empty or only `announce`.
   Fail: `mode: "cutover"` with a `reconcile` job in `retryable`; read the core log for
   `availability cutover` and the Oban error.

2. Order, count and badge read the same value. In psql (read-only):

   ```sql
   SELECT availability_state, count(*) FROM platform.ocsf_devices
   WHERE deleted_at IS NULL AND source_retired_at IS NULL GROUP BY 1;

   SELECT key, value FROM platform.device_inventory_counts
   WHERE key IN ('available', 'unavailable', 'unknown');
   ```

   Pass: the two agree per state. Fail: any difference.

3. No device keeps a NULL boolean:

   ```sql
   SELECT count(*) FROM platform.ocsf_devices
   WHERE deleted_at IS NULL AND is_available IS NULL;
   ```

   Pass: 0.

4. No per-device event burst during reconciliation. The internal logs show one
   `availability.reconciliation` summary. While `mode` is still `cutover`, there are
   no `device.available` or `device.unavailable` events. After the mode is
   `authoritative`, and only when `transition_events` is on, announce emits
   `device.available` for devices whose legacy value was false and whose merged state
   is available. It does not emit `device.unavailable`, and it does not recover a
   device whose legacy value was true or NULL.

5. Armis canonical sources in `legacy` semantics push what they pushed before: compare
   the next run's candidate counts with the previous run's.

### Roll back

From `cutover` or `authoritative`:

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.switch("legacy")'
```

The switch drains the writers, sets `legacy`, deletes waiting transition jobs and
enqueues the restore, which sets `is_available` from `device_availability_legacy` page
by page; the mirror re-derives `availability_state`. A transition job already running
publishes nothing once the mode is no longer `authoritative`. Evidence and the
per-agent ledger are kept. Verify:

```sql
SELECT count(*) FROM platform.ocsf_devices AS d
JOIN platform.device_availability_legacy AS l ON l.device_uid = d.uid
WHERE d.is_available IS DISTINCT FROM l.is_available
   OR d.availability_state IS DISTINCT FROM platform.availability_projection(d.is_available);
```

Pass: 0 once `cutover_jobs` no longer lists `restore`. To try again later, re-enter
`shadow` first (`switch("shadow")`), then `switch("cutover")`. `switch("shadow")`
returns `{:error, :restore_pending}` while the restore job is still waiting or running,
because entering `shadow` re-seeds the compatibility table from `is_available`.

## What changes for readers

- `is_available` stays a non-null boolean holding the last decided value; `unknown` is
  only in `availability_state`. A boolean `is_available:true` count can exceed the
  Available count by the unknown devices that last decided true.
- Direct writes to `is_available` stop taking effect: the next resolution of the device
  rewrites it.
- The legacy writers keep the `metadata.sweep_*` keys and the compatibility table up to
  date until stage d removes them.
