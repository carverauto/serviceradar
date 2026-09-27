# NATS JetStream Sizing Profile Runbook

Operator procedure for the Helm chart's JetStream sizing profiles
(`nats.jetstream.profile`): what the render-time budget checks, how to move a
live install to a larger profile, and how to hand a collector-owned stream back
to EventWriter. This page is not part of the published Docusaurus site under
`docs/docs/`.

Background: openspec change `update-jetstream-storage-budget` (design D5, D6,
D8).

## What the chart enforces

NATS reserves a stream's full `max_bytes` on every server that holds one of its
replicas, and it cannot place a new stream once no server has that much of
`max_file_store` left (err 10005, "insufficient storage"). The chart owns every
reservation ServiceRadar creates and checks them at render time:

| Profile | `max_file_store` | Target PVC (`nats.persistence.size`) |
| --- | --- | --- |
| `small` (default) | 30G (27.94 GiB) | 30Gi |
| `medium` | 100G (93.13 GiB) | 100Gi |
| `large` | 500G (465.66 GiB) | 500Gi |

With `nats.replicas` of 1 or 2, `small`, `medium` and `large` use their
single-server size table, the same sizes the Docker Compose presets ship (for
example `flows` is 3 GiB instead of 8 GiB in `small`). On one server every
stream reserves its full size, and on two the R3 streams still land on both
servers, so the three-server table does not fit. The `tenant-2g` profile is a
hosted-tenant plan (see "Hosted tenant plans" below).

The per-stream sizes of each profile are chart data in
`helm/serviceradar/files/jetstream-profiles.yaml`. Every size is still
overridable at its own value, and `nats.jetstream.maxFileStore` overrides the
profile's `max_file_store`. NATS reads `G` as 10^9 bytes and `Gi` as 2^30
bytes; the chart renders the exact byte count.

Two render-time checks, both raised from `templates/nats.yaml`:

1. **Reservation budget.** With `n = nats.replicas`, a stream with at least
   `n` replicas reserves its `max_bytes` on every server ("full"); the others
   are "spread". The chart computes

   ```
   need = sum(max_bytes of full)
        + ceil(sum(max_bytes * replicas of spread) / n)
        + max(max_bytes of spread)
   ```

   and fails when `need` is above 85% of `max_file_store`, listing every
   stream with its size, replicas, bucket and the value it came from. The 15%
   margin is room for streams a later release adds. `flows` and
   `ARANCINI_CAUSAL` are always counted at the collector size, even when the
   collector is disabled, because a collector that claimed its stream keeps
   that size. `nats.jetstream.allowOvercommit: true` skips this check.

2. **Disk ceiling.** The chart fails when `max_file_store` is above 94% of
   `nats.persistence.size`. A reservation ceiling larger than the volume lets
   NATS fill the disk, which is worse than an unplaceable stream, so
   `allowOvercommit` does NOT skip this check.

When the budget check fails, fix it in values: lower the size named in the
message, move to a larger profile (next section), or set `allowOvercommit`
after deciding the risk is acceptable.

## Moving a live install to a larger profile

A profile never resizes the NATS PVCs. `nats.persistence.size` feeds the
StatefulSet `volumeClaimTemplates`, which Kubernetes refuses to change on a
live StatefulSet, so selecting `medium` on a 30Gi install fails to render with
the disk-ceiling message until the volumes have been expanded. The supported
path is the standard volume-expansion procedure below. The chart does not
automate any of it.

The example moves `small` (30Gi) to `medium` (100Gi). Substitute your
namespace for `<ns>`, your Helm release for `<release>`, and `500Gi` / `large`
for the large profile.

### 1. Confirm the StorageClass can expand volumes

```
kubectl -n <ns> get pvc -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,SIZE:.status.capacity.storage | grep nats-data-serviceradar-nats
kubectl get storageclass <class> -o jsonpath='{.allowVolumeExpansion}{"\n"}'
```

The second command must print `true`. If it prints `false` or nothing, stop:
see "StorageClass without volume expansion" below.

Record the PVC UIDs so you can confirm later that the same claims survived:

```
kubectl -n <ns> get pvc -o custom-columns=NAME:.metadata.name,UID:.metadata.uid | grep nats-data-serviceradar-nats
```

### 2. Pause anything that would re-apply the old StatefulSet

If Argo CD manages the release, disable automated sync for the Application
before step 4, or it recreates the StatefulSet from the old values as soon as
it is deleted:

```
kubectl -n argocd patch application <app> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

### 3. Expand every NATS PVC and wait for the resize

The claims are `nats-data-serviceradar-nats-<ordinal>`, one per NATS replica.
Patch each one:

```
kubectl -n <ns> patch pvc nats-data-serviceradar-nats-0 -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
kubectl -n <ns> patch pvc nats-data-serviceradar-nats-1 -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
kubectl -n <ns> patch pvc nats-data-serviceradar-nats-2 -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
```

Wait until every claim reports the new capacity:

```
kubectl -n <ns> get pvc -o custom-columns=NAME:.metadata.name,CAPACITY:.status.capacity.storage,CONDITIONS:.status.conditions[*].type | grep nats-data-serviceradar-nats
```

`CAPACITY` must read `100Gi` for every claim. A `FileSystemResizePending`
condition means the volume grew but the filesystem is resized when the pod
restarts; the pod roll in step 5 does that. Any other condition, or a capacity
that never changes, is a storage-driver problem to resolve before continuing.

### 4. Delete the StatefulSet, keeping its pods and PVCs

```
kubectl -n <ns> delete statefulset serviceradar-nats --cascade=orphan
```

`--cascade=orphan` removes only the StatefulSet object. The NATS pods keep
running and serving, and the PVCs are untouched.

### 5. Upgrade with the new size and profile

Set both values together, in the values file your install uses (Git for an Argo
CD install) or on the command line:

```
helm upgrade <release> <chart> -n <ns> --reuse-values \
  --set nats.persistence.size=100Gi \
  --set nats.jetstream.profile=medium
```

For Argo CD, commit the same two values, re-enable automated sync (or sync
once by hand), and let it apply. Helm recreates the StatefulSet with the new
`volumeClaimTemplates`; it adopts the orphaned pods and the existing PVCs and
rolls the pods one at a time onto the new `max_file_store`.

### 6. Verify

```
kubectl -n <ns> rollout status statefulset/serviceradar-nats
kubectl -n <ns> get pvc -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,CAPACITY:.status.capacity.storage | grep nats-data-serviceradar-nats
kubectl -n <ns> exec deploy/serviceradar-tools -- nats server report jetstream
```

- Every NATS pod is ready and the rollout completed.
- The PVC UIDs match the ones recorded in step 1 and read `100Gi`.
- `nats server report jetstream` shows each server's reserved storage below
  85% of its new limit, and every stream is placed.

### StorageClass without volume expansion

A StorageClass without `allowVolumeExpansion: true` cannot move up a profile in
place. It needs a new install (or a new NATS StatefulSet on larger volumes)
followed by a data migration of the streams you need to keep. The chart does
not automate this. Until then, stay on the current profile and keep sizes
within its budget.

## Hosted tenant plans

A hosted tenant runtime (`helm/serviceradar/values-tenant.yaml`) is sized by its
plan, not by a PVC. The plan entitlement `nats_limits.js_disk_storage` is the
tenant's per-server JetStream file store, and the hosted control plane turns it
into a profile name when it renders the tenant's values:

| Plan `js_disk_storage` | `nats.jetstream.profile` |
| --- | --- |
| `2G` | `tenant-2g` |
| `30G` | `small` |
| `100G` | `medium` |
| `500G` | `large` |

Rules for the mapping (the control-plane change itself lives in the
serviceradar-control repository):

- Map by exact value. The profile's `max_file_store` must equal the plan's
  `js_disk_storage`; do not pick the nearest profile, and do not pass the plan
  value as `nats.jetstream.maxFileStore` next to a profile sized for a different
  store.
- A plan value with no profile needs a new profile in
  `helm/serviceradar/files/jetstream-profiles.yaml`, sized so the chart's budget
  passes with the tenant's replica counts, rather than per-stream overrides in
  the control plane. The chart rejects an unknown profile name at render time.
- Keep `nats.persistence.size` at or above `max_file_store / 0.94` (the chart's
  disk ceiling). The tenant overlay leaves it at the chart default, 30Gi, which
  covers `tenant-2g`.
- Per-stream overrides remain allowed on top of a profile and are checked by
  the same budget.

`tenant-2g` is sized for three NATS servers and the replica counts
`values-tenant.yaml` sets (KV, objects, `events`, plugins and `ARANCINI_CAUSAL`
at R3, `flows` and the EventWriter streams at R1): the most loaded server needs
1.40 GiB against a 1.58 GiB limit.

The chart checks the per-server limit only. If the control plane also enforces
`js_disk_storage` as a JetStream account limit, NATS counts a stream with more
than one replica at `max_bytes * replicas` against an un-tiered account limit,
so the same streams need about 3.4 GiB of account storage, not 2G. An account
limit for these plans must be at least that sum, or tiered per replica count.

## Reclaiming a stream after disabling a collector

`events`, `flows` and `ARANCINI_CAUSAL` each have two possible owners: a
collector (otel log-collector, flow-collector, bmp-collector) and EventWriter,
which creates them with a small fallback size when no collector has. The owner
is recorded on the stream in the metadata key `serviceradar.owner`.

Disabling a collector does not release its stream: the claim and the
collector's size stay, and nothing reconciles them. The render-time budget
already counts `flows` and `ARANCINI_CAUSAL` at the collector size, so this is
safe, but the stream keeps its larger reservation until it is reclaimed. To
hand it back to EventWriter, set the claim to `event-writer`:

```
kubectl -n <ns> exec deploy/serviceradar-tools -- nats stream edit ARANCINI_CAUSAL --metadata serviceradar.owner=event-writer -f
```

(`flows` works the same way.) EventWriter's ownership reconcile timer picks
this up at its next tick, within 5 minutes by default, with no grace period and
no core restart, and reconciles the stream to its fallback size, evicting the
oldest messages if the stream holds more than that. Check the result with
`nats stream info ARANCINI_CAUSAL`.

`--metadata` replaces the stream's whole user metadata map; ServiceRadar sets
only `serviceradar.owner`, so that is the only key to carry over.

Removing the claim instead of setting it makes the stream unclaimed:
EventWriter then waits for its grace period (15 minutes by default) before it
claims and reconciles the stream, so a collector that starts in that window
claims it first. To remove the key, write the stream's current config without
it (with `jq` on your workstation) and apply that config:

```
kubectl -n <ns> exec deploy/serviceradar-tools -- nats stream info ARANCINI_CAUSAL --json \
  | jq '.config | del(.metadata["serviceradar.owner"])' > stream.json
kubectl -n <ns> exec -i deploy/serviceradar-tools -- nats stream edit ARANCINI_CAUSAL --config /dev/stdin -f < stream.json
```

Until either change takes effect, the stream keeps the collector's reservation.
