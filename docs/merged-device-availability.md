# Merged device availability

OpenSpec changes `add-merged-device-availability` (GitHub #5789) and
`simplify-merged-availability-rollout`. Core computes one availability value per device
from every source, with explicit precedence, and persists it. The device badge, the
device order, the Available, Unavailable and Unknown counts, SRQL `availability:` and
Armis sources with `merged` semantics all read that one value.

## What the value is

- `ocsf_devices.availability_state` is `available`, `unavailable` or `unknown`, with its
  provenance (`availability_decided_by`), a conflict flag and per-agent counters.
- `is_available` stays a non-null boolean holding the last decided value. `unknown`
  exists only in `availability_state`, so an `is_available:true` count can exceed the
  Available count by the unknown devices that last decided true.
- A device with no availability evidence from any source shows **Unknown**, not
  Offline.
- A Wi-Fi device whose controller reports it up while its sweeps fail shows Online,
  with the partial-reachability marker: the controller wins.
- A per-device agent pin outranks composite-check policy.
- Per-agent ICMP/TCP results (`device_agent_availability`) are first-class and never
  pruned or rewritten; the merged value is a summary of them and the other evidence.
- Direct writes to `is_available` do not stick: the next resolution of the device
  rewrites it.

## Upgrading

Nothing to do. The release that removed the staged rollout converges every install on
merged availability by itself, whatever stage it had reached:

1. For legacy or shadow installs, the migration
   `20261026220000_converge_merged_availability` seeds missing
   `device_availability_legacy` rows from `is_available`, leaving existing rows intact.
   It then removes the rollout objects.
2. Shortly after start-up, core resolves every device once, rebuilds the inventory
   counts, and, for an install that was not yet on merged availability, publishes one
   `availability.reconciliation` summary event whenever live devices exist, even if
   all difference counts are zero. The first decision for a device with legacy-mirror
   provenance emits no per-device event. An existing unhealthy readiness warning is
   recorded as healthy, retaining its history.
3. For those non-authoritative upgrades, when `transition_events` is on, devices that
   the old value held down and the merged value holds available get one
   `device.available` recovery event, so alerts opened by the old flapping close through
   the normal recovery path.

The internal `availability_settings.converged_at` timestamp is a one-time upgrade
convergence marker, not an operator mode; nothing user-facing sets or reads it. The
migration sets it immediately for authoritative deployments and installs with no devices.
Otherwise, until the full resolve and rollup rebuild finish, every resolution path reads
a device with NULL provenance as the legacy mirror would have shown it. This preserves
its last boolean when evidence is unknown and suppresses its first transition, even if
ordinary ingestion resolves it before the reconciliation job. The job then sets the
marker once; new devices subsequently follow normal first-decision behavior.

A fresh install starts on merged availability and publishes no reconciliation summary.

### Checking the result

Each check has a failure branch. In psql (read-only):

```sql
SELECT availability_state, count(*) FROM platform.ocsf_devices
WHERE deleted_at IS NULL AND source_retired_at IS NULL GROUP BY 1;

SELECT key, value FROM platform.device_inventory_counts
WHERE key IN ('available', 'unavailable', 'unknown');
```

Pass: the two agree per state. Fail: any difference, or a `ReconcileWorker` job left in
`retryable` (read the core log for `merged availability reconciliation`).

```sql
SELECT count(*) FROM platform.ocsf_devices AS d
LEFT JOIN platform.device_availability_legacy AS l ON l.device_uid = d.uid
WHERE l.device_uid IS NULL;
```

Pass: 0. Every device has a legacy value for Armis sources with `legacy` semantics.

## Device events

The resolver is the only emitter of `device.available` and `device.unavailable`. They
are published only when the deployment setting `transition_events` is on and, for a
transition decided by a sweep group's per-agent results, only when that group has
availability events enabled. The setting started on exactly when some sweep group
already emitted availability events. Support can change it:

```bash
kubectl -n <namespace> exec deploy/serviceradar-core -c core-elx -- \
  /app/bin/serviceradar_core_elx rpc \
  'ServiceRadar.Inventory.Availability.Operator.transition_events(true)'
```

## Armis northbound: a per-source choice

What an Armis source pushes is chosen per source:

| Source setting | Pushes |
|---|---|
| An availability agent selected | That agent's own ICMP/TCP result for each device. |
| No agent, `legacy` semantics | The value the pre-merge availability writers compute, kept in `device_availability_legacy` for every device. Every source that existed before merged availability starts here. |
| No agent, `merged` semantics | The merged `availability_state`; devices whose state is `unknown` are withheld. New sources start here. |

A `legacy` source moves to `merged` only when an operator clicks **Adopt merged
availability** on its settings page, which first shows how many linked Armis IDs would
change and how many would be withheld.

The upgrade preserves pushes on the production population path, subject to the
[accepted incomplete-rollout exceptions](../openspec/changes/simplify-merged-availability-rollout/design.md#decision-1a-merged-armis-sources-on-an-install-that-never-cut-over).
On an install that had not cut over to merged availability before this release, a source
created with `merged` semantics and no agent was in fact pushing the legacy value, so
the upgrade sets it to `legacy` semantics to keep pushing that value. Each such change
is recorded:

```sql
SELECT integration_source_id, from_semantics, to_semantics, reason, changed_at
FROM platform.integration_source_availability_semantics_changes ORDER BY id;
```
