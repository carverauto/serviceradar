# StarRocks 3.5 to 4.1 upgrade

Fresh installs use 4.1.3. Existing clusters follow 3.5.21 -> 4.0.14 -> 4.1.3.
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

Complete this sequence for target 4.0.14, verify it, create and synchronize a
metadata image, then repeat for target 4.1.3. Stop on any failed node or health
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
     --type merge -p '{"spec":{"starRocksFeSpec":{"image":"starrocks/fe-ubuntu:4.0.14","updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}}'
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

For the second hop, repeat steps 1-5 with target 4.1.3 under the same compute-first, follower-before-leader, image-synchronization, and backup/health prerequisites. The compute image patch is:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksCnSpec":{"image":"starrocks/cn-ubuntu:4.1.3"}}}'
   ```

   for shared-data, or:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksBeSpec":{"image":"starrocks/be-ubuntu:4.1.3"}}}'
   ```

   for shared-nothing. The atomic frontend patch is:

   ```sh
   kubectl --context "$SR_CONTEXT" -n "$SR_NAMESPACE" patch starrockscluster "$SR_CLUSTER" \
     --type merge -p '{"spec":{"starRocksFeSpec":{"image":"starrocks/fe-ubuntu:4.1.3","updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}}'
   ```

At completion, persist the final 4.1.3 pins in the Helm release using its
existing profile and operational overrides, with
`initPassword.isInstall=false`. Verify the rendered changes first: no storage,
credential, architecture, or resource change should accompany the image pins.
Restore the frontend's recorded update strategy after every frontend runs
4.1.3 and its metadata image has synchronized, as in step 5. Explicitly remove
or replace the temporary cluster override and verify the resulting
StatefulSet strategy; omitting `OnDelete` from Helm values does not prove that
a manually added field was removed from the live cluster.

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
- [Operator 1.11.7 component update strategies](https://github.com/StarRocks/starrocks-kubernetes-operator/blob/v1.11.7/pkg/apis/starrocks/v1/component_type.go)
