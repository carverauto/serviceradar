# Merged device availability: rollout runbook

OpenSpec change `add-merged-device-availability` (GitHub #5789). Merged availability
makes one resolver the only writer of `ocsf_devices.availability_state` and
`is_available`, so the device badge, the device order, the Available and Unknown counts,
SRQL `availability:` and Armis canonical sources in `merged` semantics all read one value.

## What you need to do: nothing

Core moves through the modes by itself. On a fresh install or an upgrade, with the
default mode control `auto`:

1. Within a minute of the release running, core switches `legacy` to `shadow`. Nothing
   visible changes: the legacy writers still own `is_available`, and the resolver writes
   its decisions to a separate shadow table.
2. Core resolves every device once in shadow, then checks the readiness conditions
   every minute. When all of them hold, it runs the cutover: it drains the writers,
   copies every device's current value into the compatibility table, re-resolves every
   device with no per-device event, and moves to `authoritative`.
3. One `availability.reconciliation` summary event reports how many devices moved to
   available, unavailable and unknown.

An install with no devices and no sweep groups is ready as soon as its first full pass
has run, so it reaches `authoritative` within a few minutes of starting.

**What users see after the cutover.** A device with no availability evidence from any
source shows **Unknown** instead of Offline. Before merged availability, such a device
showed the last boolean a legacy writer, or the device-creation default, had left. A
device whose managing controller reports it up while its sweeps fail shows Online,
with the partial-reachability marker.

## Readiness conditions

All must hold. None is a timer.

| Condition | Holds when |
|---|---|
| `capture_backfill` | The stage-a backfill has nothing left: every device's `availability_state` is the projection of its `is_available`, and every unreachable per-agent row has its counter. |
| `shadow_resolve` | A full shadow resolution of every live device started after entering `shadow` and finished. |
| `invalidation_backlog` | At most 500 entries wait in the invalidation log, which is one resolver pass. |
| `sweep_groups` | Every active sweep group has completed a run, per agent, that started after entering `shadow`. A group is active for an agent when it is enabled and that agent started a run of it in the last 24 hours. A disabled group, or one that no connected agent runs, does not block. |
| `policy_violations` | The divergence report counts no policy violation: no negative-control vantage point reaches a device it is expected not to reach. |

If the conditions are still unmet 24 hours after entering `shadow`, core stays in
`shadow` and records the core health check `availability_cutover_readiness` as
unhealthy. Its metadata names the unmet conditions. The cutover clears it. Core never
cuts over while a condition is unmet.

The Settings page **Network Services > Availability Sources** shows the mode, the
control and each condition.

## Holding and rolling back

The mode control lives on the same Settings page:

| Control | Effect |
|---|---|
| `auto` (default) | Progress automatically, and cut over when ready. |
| `hold_shadow` | Stay in `shadow`, or return to it, and never cut over. From `cutover` or `authoritative`, core rolls back to `legacy` first and re-enters `shadow` once the restore has finished. |
| `hold_legacy` | Stay in `legacy`, or roll back to it. From `cutover` or `authoritative`, the rollback restores `is_available` from the compatibility table. |

The rollback is the one an operator ran before: core drains the writers, sets
`legacy`, deletes waiting transition jobs and restores `is_available` page by page.
The mirror re-derives `availability_state`. Evidence and the per-agent ledger are kept.
Switching back to `auto` progresses again from `legacy`.

**GitOps installs** can pin the control with the Helm value
`core.availability.modeControl` (`auto`, `hold_legacy` or `hold_shadow`), which reaches
core as `SERVICERADAR_AVAILABILITY_MODE_CONTROL`. A pin wins over the Settings value,
and the Settings page then shows the control read-only. The chart refuses any other
value. If core is given one some other way, it logs an error and holds the mode where
it is. Set the pin before an upgrade that should stay held, because replicas may
disagree on the env while the pin rolls out.

Transition events are unchanged. `transition_events` keeps the value the cutover
migration set: on exactly when some sweep group already emitted availability events.

Armis northbound sources are unaffected. A source without a selected agent keeps
pushing the legacy value until someone adopts `merged` for it in its settings. Nothing
is adopted automatically.

## Operator appendix

Support commands, for diagnosis or to act ahead of the progression. None is needed for
a rollout. Set the target once:

```bash
CORE='kubectl -n <namespace> exec deploy/serviceradar-core -c core-elx -- /app/bin/serviceradar_core_elx'
```

### Status

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.status()'
```

It prints the mode, the stored control and the pin, when the deployment entered
`shadow`, the last readiness evaluation (`readiness.unmet` names what is blocking),
the transition-event setting, the invalidation backlog and the cutover jobs not yet
finished.

The divergence report shows what the cutover would change, without changing anything:

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.report()'
```

### Set the control

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.control("hold_legacy")'
```

It is refused while the control is pinned.

### Switch now

`switch/1` switches at once and sets the control that keeps the mode there, so the
progression does not undo it:

```bash
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.switch("cutover")'  # control auto, no readiness wait
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.switch("legacy")'   # control hold_legacy
$CORE rpc 'ServiceRadar.Inventory.Availability.Operator.switch("shadow")'   # control hold_shadow
```

- `switch("cutover")` and `switch("legacy")` set the control in the same transaction
  as the switch, so a refused switch (for example `switch("cutover")` from `legacy`)
  leaves the control as it was.
- `{:error, :mode_switch_busy}` means a writer held the lock for the whole retry
  window (about 10 s); run the switch again.
- `switch("shadow")` returns `{:error, :restore_pending}` while a restore is still
  waiting or running, because entering `shadow` re-seeds the compatibility table from
  `is_available`. From `cutover` or `authoritative` it returns
  `{:error, {:unsupported_switch, ...}}`; the `hold_shadow` control it set then rolls
  back and re-enters `shadow` by itself.

### Verify a cutover

Each check has a failure branch; do not report success until all pass.

1. The reconciliation finished. Pass: `status()` shows `mode: "authoritative"` and
   `cutover_jobs` empty or only `announce`. Fail: `mode: "cutover"` with a `reconcile`
   job in `retryable`; read the core log for `availability cutover` and the Oban
   error.

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
   is available. It does not emit `device.unavailable`.

5. Armis canonical sources in `legacy` semantics push what they pushed before: compare
   the next run's candidate counts with the previous run's.

### Verify a rollback

```sql
SELECT count(*) FROM platform.ocsf_devices AS d
JOIN platform.device_availability_legacy AS l ON l.device_uid = d.uid
WHERE d.is_available IS DISTINCT FROM l.is_available
   OR d.availability_state IS DISTINCT FROM platform.availability_projection(d.is_available);
```

Pass: 0 once `cutover_jobs` no longer lists `restore`.

## Modes

| Mode | Who writes `is_available` | `availability_state` | Transition events |
|---|---|---|---|
| `legacy` | legacy writers | mirror of `is_available` | legacy publishers |
| `shadow` | legacy writers | mirror; the resolver writes `device_availability_shadow` | legacy publishers |
| `cutover` | resolver (legacy writers write `device_availability_legacy` only) | resolver | none per device |
| `authoritative` | resolver | resolver | resolver, through the outbox |

`cutover` lasts while the reconciliation job re-resolves every device; the job moves the
mode to `authoritative` itself.

## What changes for readers

- `is_available` stays a non-null boolean holding the last decided value; `unknown` is
  only in `availability_state`. A boolean `is_available:true` count can exceed the
  Available count by the unknown devices that last decided true.
- Direct writes to `is_available` stop taking effect: the next resolution of the device
  rewrites it.
- The legacy writers keep the `metadata.sweep_*` keys and the compatibility table up to
  date until stage d removes them.
