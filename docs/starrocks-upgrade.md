# StarRocks 3.5 to 4.1 upgrade

Fresh installs use 4.1.7. A 3.5 cluster follows 3.5.21 -> 4.0.17 -> 4.1.7.
A cluster already on 4.1 takes the [4.1 patch roll](#41-patch-roll) instead.
The farm01 lab has [its own notes](#farm01-shared-nothing-lab), and the Docker
Compose warehouse has [a separate procedure](#docker-compose-allin1), because
its image keeps the StarRocks binaries in the data volume.
Keep the existing shared-data or shared-nothing architecture, storage volumes,
credentials, JDBC driver, replica counts, and resource settings throughout.

The final image pins are not an in-place upgrade command. Do not apply
`k8s/starrocks/values-cluster.yaml` to all components at once on a 3.5 cluster.
The operator's default StatefulSet update order follows pod ordinals; it does
not establish that a frontend is a follower before restarting it.

## Prerequisites

- Record the Helm release revision and the current cluster specification in a
  private operational workspace. They can contain credentials and must never
  enter Git, fixtures, or the PR.
- Verify all frontends and compute nodes are alive with no reported errors.
  Use `SHOW FRONTENDS`, `SHOW COMPUTE NODES` for shared-data, or `SHOW BACKENDS`
  for shared-nothing. Confirm the running versions with SQL, not only pod tags.
- Have a recoverable backup of frontend metadata and the telemetry storage.
  For shared-data, that includes the object store; for shared-nothing, it
  includes the backend storage volumes. Do not delete or recreate PVCs.
- Read the 4.0 and 4.1 release notes, confirm capacity for sequential restarts,
  and verify the pinned FE/BE/CN images can be pulled by the cluster.
- Confirm ingestion and representative telemetry reads are healthy before
  starting. Keep JetStream retention sufficient to cover an ingestion pause.
- Use the existing frontend root credential inside its pod. Do not display it
  or copy it into a command argument, Helm values, or a new Secret.

The installed operator/chart remains 1.11.7. Choose the Kubernetes context,
namespace, cluster resource, and frontend StatefulSet explicitly for each
cluster; the commands below use `SR_CONTEXT`, `SR_NAMESPACE`, `SR_CLUSTER`,
and `SR_FE_STATEFULSET` for those selected values.

## Each version hop

Complete this sequence for target 4.0.17, verify it, create and synchronize a
metadata image, then repeat for target 4.1.7. Stop on any failed node or health
check; do not continue to the next phase or silently roll back.

1. Upgrade only compute nodes. Set the cluster's `starRocksCnSpec.image` to
   `starrocks/cn-ubuntu:<target>` in shared-data, or its
   `starRocksBeSpec.image` to `starrocks/be-ubuntu:<target>` in shared-nothing.
   Leave `starRocksFeSpec.image` at the previous version. Wait for the entire
   compute StatefulSet to finish its sequential rollout. Check every node's
   SQL version and `Alive` value, and verify ingestion and telemetry reads.
   Before relying on `kubectl rollout status`, confirm the operator has
   reconciled the requested image into the compute StatefulSet template and
   its controller has observed that generation. Otherwise the command can
   report completion for the previous image revision.
   For shared-nothing, apply the upstream tablet-balancing compatibility
   configuration before the hop and restore the recorded original values only
   after every backend is alive; see the upstream upgrade procedure below.

2. Set the frontend image and `OnDelete` strategy **in one atomic cluster
   patch**, preventing a leader-first automatic restart. For the first hop:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksFeSpec":{"image":"starrocks/fe-ubuntu:4.0.17","updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}}'
   ```

   Confirm the operator has reconciled the frontend StatefulSet's template
   image and `OnDelete` strategy **before deleting any pod**:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" get statefulset "$SR_FE_STATEFULSET" \
     -o jsonpath='{.spec.updateStrategy.type}{" "}{.spec.template.spec.containers[*].image}{"\n"}'
   ```

3. Identify the current leader with `SHOW FRONTENDS`, map its hostname to the
   frontend pod, and restart followers individually by deleting one selected
   pod at a time. Wait for that pod to become Ready, then verify through SQL
   that it is alive, on the target version, and caught up with the leader's
   journal. Re-check leader identity before every restart. Restart the leader
   only after all followers have upgraded and recovered. A changed leader
   identity requires re-evaluating which pod is safe to restart next.

4. Verify all frontend and compute versions, quorum, node health, ingestion,
   catalog-backed queries, and telemetry reads. Run `ALTER SYSTEM CREATE IMAGE`
   on the leader, then wait for successful synchronization to **all follower
   frontends**, checking the leader's real `fe.log` output and follower image
   state. Record this evidence privately before starting the next hop. If image
   creation or synchronization fails, the next hop must not begin.

   Check the actual log wording: version 4.0 reports `push succeeded`, while
   upstream examples use `push successful`. A checkpoint worker can already
   hold the image it created, leaving fewer pending push recipients than there
   are followers. Require every pending push to succeed, then independently
   verify that every follower holds the new frontend image generation and the
   leader's StarMgr image generation. A log match alone is insufficient.

5. After all frontends run the completed hop's version and metadata-image
   synchronization has passed, restore the recorded frontend update strategy
   **without changing its image**, before requesting the next compute image.
   Operator 1.11.7 with `waitForFullRollout=true` blocks compute reconciliation
   while the frontend uses `OnDelete`: it checks `currentRevision` against
   `updateRevision` and reports that rollout status requires `RollingUpdate`,
   even when every frontend pod is updated and Ready.

   If the original cluster specification omitted `updateStrategy`, remove the
   temporary override to restore the default `RollingUpdate` strategy:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksFeSpec":{"updateStrategy":null}}}'
   ```

   If the original specification had an explicit strategy, restore that
   recorded value instead. Re-query the StatefulSet strategy, unchanged
   frontend image, pod identities, and rollout status. This normalization
   must not restart a frontend or happen while frontend versions are mixed.
   Keep `waitForFullRollout` enabled. For the next frontend hop, again set
   `OnDelete` and its new image atomically before restarting any pod.

For the second hop, repeat steps 1-5 with target 4.1.7 under the same compute-first, follower-before-leader, image-synchronization, and backup/health prerequisites. The compute image patch is:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksCnSpec":{"image":"starrocks/cn-ubuntu:4.1.7"}}}'
   ```

   for shared-data, or:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksBeSpec":{"image":"starrocks/be-ubuntu:4.1.7"}}}'
   ```

   for shared-nothing. The atomic frontend patch is:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksFeSpec":{"image":"starrocks/fe-ubuntu:4.1.7","updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}}'
   ```

At completion, persist the final 4.1.7 pins in the Helm release using its
existing profile and operational overrides, with
`initPassword.isInstall=false`. Verify the rendered changes first: no storage,
credential, architecture, or resource change should accompany the image pins.
Restore the frontend's recorded update strategy after every frontend runs
4.1.7 and its metadata image has synchronized, as in step 5. Explicitly remove
or replace the temporary cluster override and verify the resulting
StatefulSet strategy; omitting `OnDelete` from Helm values does not prove that
a manually added field was removed from the live cluster.

## 4.1 patch roll

A patch upgrade within 4.1, such as 4.1.3 -> 4.1.7, is one hop: steps 1-5
above with the target patch version, under the same prerequisites. Upstream
supports a direct jump across patch versions; there is no intermediate
version to visit and no second hop to gate on a metadata image, though
creating one after the frontends finish (step 4) is still the checkpoint a
rollback starts from.

Two things apply whenever a cluster reaches 4.1.6 or later from an earlier
release, including the second hop of a 3.5 upgrade:

- **Online optimize is opt-in.** 4.1.6 changed the frontend default of
  `enable_online_optimize_table` from `true` to `false`. Both lab values files
  set it to `true` in the frontend config, so the frontend configuration
  changes in the same roll as the image. The operator restarts frontends when
  their ConfigMap changes, so apply that configuration while the frontend uses
  `OnDelete` (after step 2, before deleting any pod) and let each frontend
  pick up image and configuration in one restart. Add the line to the
  release's live values (`helm get values`) rather than re-applying these
  files, unless the release already matches them: a live release can carry
  operational overrides, such as a compute `mem_limit` or init container,
  that a render from the files would change and restart compute nodes for.
  Confirm the strategy is still `OnDelete` after applying it. After step 3, check every frontend
  reports the key as `true` with `ADMIN SHOW FRONTEND CONFIG LIKE
  'enable_online_optimize_table'`. `ADMIN SET FRONTEND CONFIG` changes only
  the frontend it runs on and does not survive a restart.
- **A 4.1.0-4.1.5 compute data cache starts cold once.** On x86, 4.1.0-4.1.5
  key the data cache with CRC-32C, while 4.0 and 4.1.6+ use MurmurHash3
  (StarRocks #79262). A shared-data cluster going from 4.1.0-4.1.5 to 4.1.6+
  loses every cached block once, and mixed-version compute nodes miss each
  other's peer cache during the roll. Expect a temporary rise in
  object-storage reads and query latency until the cache refills; a rollback
  to an earlier 4.1 patch invalidates it again. A 4.0 -> 4.1.7 hop keeps its
  cache.

To roll back a patch upgrade, follow the upstream downgrade order, the
reverse of the upgrade: create and synchronize a metadata image, then
frontends (followers first, leader last, under `OnDelete`), then compute
nodes.

## farm01 (shared-nothing lab)

farm01 runs a shared-nothing `StarRocksCluster` (three frontends, three
backends) on 3.5.21 from `values-cluster.yaml`. It is not managed by Argo CD,
and other people deploy pinned builds there, so the release's live state is
the source of truth until proven otherwise. It takes both hops above,
3.5.21 -> 4.0.17 -> 4.1.7, with these additions:

1. Before anything else, diff what is running against what the repository
   would render, as its own step, and stop on any difference you cannot
   explain:

   ```sh
   helm --kube-context farm01 -n starrocks get manifest starrocks-lab > live.yaml
   helm template starrocks-lab starrocks/starrocks --version 1.11.7 -n starrocks \
     -f k8s/starrocks/values-cluster.yaml --set initPassword.isInstall=false > repo.yaml
   diff live.yaml repo.yaml
   ```

   Expect the image tags and the `enable_online_optimize_table` line to
   differ; anything else is drift. Carry the live values forward with
   `helm upgrade --reuse-values` rather than re-applying the files, and
   reconcile the files to the live release afterwards.
2. Backends are the compute step (`starRocksBeSpec.image`). Before each
   backend roll, disable tablet scheduling and balancing, and restore the
   recorded values only after every backend reports `Alive` on the new version:

   ```sql
   ADMIN SET FRONTEND CONFIG ("tablet_sched_max_scheduling_tablets" = "0");
   ADMIN SET FRONTEND CONFIG ("tablet_sched_max_balancing_tablets" = "0");
   ADMIN SET FRONTEND CONFIG ("disable_balance" = "true");
   ADMIN SET FRONTEND CONFIG ("disable_colocate_balance" = "true");
   ```

   These settings apply to the frontend they run on, so run them against the
   leader and record the original values first with `ADMIN SHOW FRONTEND
   CONFIG LIKE ...`.
3. Add `enable_online_optimize_table = true` to the frontend configuration
   in the second hop only, inside its `OnDelete` window as described in the
   [4.1 patch roll](#41-patch-roll). 3.5 and 4.0 also default it to `false`.
   Leave it off for the 4.0.17 hop.
4. farm01's warehouse also answers SrqlParity dispatches that land on its
   executor. Do not dispatch SrqlParity while farm01 is mid-upgrade. After
   both hops, run one dispatch on each cluster.
5. Shared-nothing has no data cache, so the 4.1.6 cache-key change does not
   apply.

Within the first hop, a return to 3.5.21 follows the upstream downgrade order
(frontends first, followers before the leader, then backends) and starts from
the metadata image taken before the hop. After the second hop, rollback is
limited to 4.0.6 or later, which in practice means back to 4.0.17.

## Docker Compose (allin1)

The Compose `starrocks` service runs `starrocks/allin1-ubuntu`, one frontend
and one backend in a single container. That image installs StarRocks itself
under `/data/deploy/starrocks`, and Compose mounts the `starrocks-data` volume
at `/data`. Docker fills a named volume from the image only when the volume is
empty, so an existing warehouse keeps the binaries, start script and
configuration of the version that first created it. **Changing the image tag
alone does not upgrade it**: the container starts the old StarRocks from the
volume. Each hop therefore builds a fresh volume from the new image and moves
the frontend metadata and backend storage into it.

The Compose default stays `starrocks/allin1-ubuntu:3.5.21` until a release
moves it with an upgrade note. `STARROCKS_IMAGE` selects the image for each
hop. This procedure has not been exercised end to end against a populated
warehouse. Run it on a copy first, and do not continue past a failed check.

It takes two hops, 3.5.21 -> 4.0.17 -> 4.1.7. There is one frontend and one
backend, so compute-before-frontend ordering does not apply; the container
restarts both together. Free disk for about three copies of the volume: the
backup, the new volume, and the live volume.

Set these once (the volume name follows `SERVICERADAR_VOLUME_PREFIX`, default
`serviceradar`):

```sh
VOL=serviceradar_starrocks-data
q() { docker exec -i serviceradar-starrocks sh -c \
  'MYSQL_PWD="$STARROCKS_ROOT_PASSWORD" mysql -h127.0.0.1 -P9030 -uroot --batch -e "$0"' "$1"; }
```

`docker exec` runs with the container's configured environment, which still
carries `STARROCKS_ROOT_PASSWORD`; the password never appears on a command
line.

For each hop, with `FROM` the running version and `TO` the target:

1. **Check and record.** `q "SELECT current_version()"` must print `FROM`.
   `q "SHOW FRONTENDS"` and `q "SHOW BACKENDS"` must show `Alive` true. Record
   the row count of every table in `serviceradar` and the newest timestamp of
   `events` and `timeseries_metrics`. Make sure no `SHOW ALTER TABLE COLUMN`
   or `SHOW ALTER TABLE OPTIMIZE` job is running.
2. **Create a metadata image.** Run `q "ALTER SYSTEM CREATE IMAGE"`. Wait until
   a new `image.<n>` with a higher `n` appears under
   `/data/deploy/starrocks/fe/meta/image/v2/`
   (`docker exec serviceradar-starrocks ls /data/deploy/starrocks/fe/meta/image/v2/`).
   There are no followers to push to; a new generation on disk is the check.
3. **Stop the warehouse and back it up.** Run `docker compose stop starrocks`.
   EventWriter retries its loads and JetStream holds the backlog, so keep the
   window shorter than the stream retention. Then:

   ```sh
   docker volume create "$VOL-backup-$FROM"
   docker run --rm -v "$VOL":/from:ro -v "$VOL-backup-$FROM":/to alpine:3.21.3 \
     sh -c 'cp -a /from/. /to/'
   ```

4. **Build the new volume from the target image.** Mounting an empty volume
   makes Docker copy the image's `/data` into it:

   ```sh
   docker volume create "$VOL-next"
   docker run --rm --entrypoint /bin/true -v "$VOL-next":/data \
     "starrocks/allin1-ubuntu:$TO"
   ```

   Then replace its empty metadata and storage with the live ones:

   ```sh
   docker run --rm -v "$VOL":/from:ro -v "$VOL-next":/to alpine:3.21.3 sh -c '
     set -eu
     test -d /to/deploy/starrocks/fe/lib
     rm -rf /to/deploy/starrocks/fe/meta /to/deploy/starrocks/be/storage
     cp -a /from/deploy/starrocks/fe/meta /to/deploy/starrocks/fe/meta
     cp -a /from/deploy/starrocks/be/storage /to/deploy/starrocks/be/storage'
   ```

   The new volume carries the target image's own `fe.conf` and `be.conf`.
   Edits made by hand inside the old volume are not carried; reapply them.
   For the hop to 4.1.7 only, enable online optimize in the new frontend
   configuration:

   ```sh
   docker run --rm -v "$VOL-next":/to alpine:3.21.3 sh -c \
     'echo "enable_online_optimize_table = true" >> /to/deploy/starrocks/fe/conf/fe.conf'
   ```

5. **Swap the volume contents.** The Compose volume name is fixed, so copy the
   new tree into it. The backup from step 3 is the way back:

   ```sh
   docker run --rm -v "$VOL":/to -v "$VOL-next":/from:ro alpine:3.21.3 sh -c '
     set -eu
     find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} +
     cp -a /from/. /to/'
   ```

6. **Start the target.** Set `STARROCKS_IMAGE=starrocks/allin1-ubuntu:$TO` in
   `.env`, then run `docker compose --profile starrocks up -d starrocks`. Wait
   for `docker logs serviceradar-starrocks` to show
   `StarRocks root password is set`.
7. **Verify, each check able to fail.** Each of these must hold:
   - `q "SELECT current_version()"` prints `TO`. If it still prints `FROM`,
     the container started the old binaries: stop and recheck steps 4 and 5.
   - Frontend and backend are `Alive`.
   - Every table's row count is at least the count recorded in step 1.
   - New `events` and `timeseries_metrics` rows arrive with timestamps after
     the start.
   - The EventWriter logs carry no new Stream Load failures beyond retries.
   - On 4.1.7, `q "ADMIN SHOW FRONTEND CONFIG LIKE 'enable_online_optimize_table'"`
     shows `true`.

   Then run `ALTER SYSTEM CREATE IMAGE` again and confirm a new generation, as
   in step 2. That image gates the next hop.
8. Remove `$VOL-next`. Keep `$VOL-backup-$FROM` until the next hop has
   verified.

To roll back a hop, run `docker compose stop starrocks`, then copy the step 3
backup back into `$VOL`:

```sh
docker run --rm -v "$VOL":/to -v "$VOL-backup-$FROM":/from:ro alpine:3.21.3 sh -c '
  set -eu
  test -d /from/deploy/starrocks/fe/meta
  find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a /from/. /to/'
```

Set `STARROCKS_IMAGE=starrocks/allin1-ubuntu:$FROM` in `.env` and start it as
in step 6; `q "SELECT current_version()"` must print `FROM`. Loads written to the
warehouse after the backup are lost unless JetStream still holds them. Once a
warehouse has run 4.1, it cannot go back below 4.0.6, so a return to 3.5.21 is
only this restore of the 3.5.21 backup.

## Completion and rollback limits

Verify actual SQL versions on every node and confirm new telemetry arrives
after the rollout, not merely that pods are Ready. Exercise an existing JDBC
catalog query on an allowed control-plane relation.

Never use `helm rollback` blindly for this upgrade: it can restore incompatible
images and restart components in the wrong order. After a cluster has reached
4.1, upstream supports downgrade only to 4.0.6 or later. A return to 3.5 requires
a separately planned restore of compatible pre-upgrade metadata and storage,
not just an image change. Follow the upstream downgrade procedure for any
supported downgrade, preserving its required component order.

## Upstream references

- [Upgrade procedure and metadata synchronization](https://docs.starrocks.io/docs/deployment/manage_deployment/upgrade/)
- [4.0 release notes](https://docs.starrocks.io/releasenotes/release-4.0/)
- [4.1 release notes and downgrade limits](https://docs.starrocks.io/releasenotes/release-4.1/)
- [Downgrade procedure and component order](https://docs.starrocks.io/docs/deployment/manage_deployment/downgrade/)
- [Operator 1.11.7 component update strategies](https://github.com/StarRocks/starrocks-kubernetes-operator/blob/v1.11.7/pkg/apis/starrocks/v1/component_type.go)
