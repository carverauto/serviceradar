# StarRocks operator

This directory is the **lab** install: kube contexts `carverauto` and `farm01`.
Those clusters are self-managed k3s used for ServiceRadar development and test.
They are not the SaaS control plane.

The cloud/SaaS product runs on **Akamai LKE**. Do not copy lab node procedures
(SSH, `/etc/sysctl.d`, `gitops/VMs/setup-new-VM.sh`) onto LKE workers. Hosted
StarRocks is the shared-data profile from
`openspec/changes/add-starrocks-telemetry-analytics` (object storage + CN
cache); LKE node sysctl still belongs with the SaaS cluster, not here.

Cluster-scoped operator, pinned to chart/operator **1.11.7**. The default lab
`StarRocksCluster` is shared-nothing FE+BE (`values-cluster.yaml`), pinned to
StarRocks **3.5.21**. Carverauto demo uses the shared-data overlay
`values-cluster-shared-data.yaml` (CN + Linode analytics bucket). Farm01
stays on the shared-nothing file.

The CNPG JDBC catalog (`cnpg_platform`) is opt-in and off by default. FE/BE
expect the pinned PostgreSQL JDBC driver at
`file:///opt/starrocks/jdbc/postgresql.jar` (checksum in
`third_party/jdbc/postgresql.pin`). `values-cluster.yaml` has a checksummed
alpine initContainer that mounts an emptyDir `jdbc` volume (chart 1.11.7
ignores extra storageVolumes; emptyDir is the extra-volume API) so FE/BE
share `file:///opt/starrocks/jdbc/postgresql.jar`. The initContainer
re-fetches the pinned jar (BusyBox wget) when the checksum is missing.
Nodes that cannot resolve repo1.maven.org will CrashLoop the init
container; do not roll those until the jar is available in-cluster.
Demo CNPG now has an additive NetworkPolicy allowing namespace
`starrocks` on 5432. Lab FE has `cnpg_platform`, created by the chart's
catalog Job from a generated reader Secret. Helm default catalog stays
off; `values-demo.yaml` enables it with empty cutover. Do not let the
Frontend download Maven at catalog-create time.

The catalog connects to CNPG as `serviceradar_starrocks_reader`. Two things
converge that role, so there is nothing to grant by hand:

| Object | Granted |
| --- | --- |
| schema `platform` | `USAGE` |
| `platform.netflow_local_cidrs_catalog` | `SELECT` |
| `platform.ocsf_devices` | `SELECT (uid, hostname, ip)` |
| `platform.device_alias_states` | `SELECT (device_id, alias_type, state, alias_value)` |
| `platform.netflow_exporter_cache` | `SELECT (device_uid, sampler_address)` |
| `platform.netflow_interface_cache` | `SELECT (sampler_address, if_index, if_name, if_speed_bps)` |

Nothing else is reachable: `CatalogAllowlist` rejects any other table before
the SQL leaves core, and the grants above are column-scoped to exactly what the
compiled subqueries read. Telemetry hypertables and
`network_credential_secrets` are never granted.

Core migration `20260918120000_create_starrocks_catalog_reader_role` creates the
role and issues the grants, but only where the migrating connection holds
`SUPERUSER` or `CREATEROLE`. On a default CNPG cluster the application user is
the database owner and holds neither, so there it skips the create with a
`NOTICE` and, because every grant is role-existence guarded, issues nothing --
deliberately, since role DDL without the privilege aborts the whole migration
run (see `20260716220000_create_cold_tier_export_role` for the same hazard and
guard).

That alone would never converge on the documented workflow: install with the
catalog off, enable it later. By the time CNPG creates the role the migration is
already recorded in `schema_migrations` and does not replay. So setting
`analytics.starrocks.catalog.enabled` also renders
`serviceradar-starrocks-catalog-reader`, a post-install/post-upgrade Job that
connects as the CNPG superuser and idempotently applies the same create and
grants. Enabling the catalog after install therefore converges on the next
`helm upgrade`, and no operator has to issue a GRANT by hand.

Login and password stay with CNPG `managed.roles`: enabling the catalog renders
the role into the cluster manifest with `login: true` and the password from the
reader Secret (`analytics.starrocks.catalog.readerPasswordSecret`, default
`serviceradar-starrocks-reader`), reconciled continuously so it survives
failover. Neither the migration nor the Job ever sets login or password.

Nobody creates that Secret by hand. The chart's secret generator mints it when
it is missing and never rotates it, and the `serviceradar-starrocks-catalog`
Job reads the same Secret to build `CREATE EXTERNAL CATALOG`, so the two sides
cannot disagree. The Job drops the catalog before creating it: a JDBC catalog
keeps the password it was created with, so `IF NOT EXISTS` could never deliver
a corrected one. A reader role whose Secret is missing has no password at all,
and the symptom is remote from the cause -- the Frontend logs
`password authentication failed for user "serviceradar_starrocks_reader"` and
every catalog-joined flow query (exporter and interface names, per-device
filters, direction) fails while plain flow queries keep working.
`catalog.secretName` (key `createSql`) remains as an override for a statement
the Job does not produce; with `secrets.autoGenerate` off, create the reader
Secret with `username` and `password` keys before enabling the catalog.

`NOLOGIN` rather than a `LOGIN` role with no password is deliberate: an empty
password is an absence of a credential, not of capability, and a `trust`/`peer`
line or a later `ALTER ROLE` reaches straight through it. Compose and developer
databases are not covered by the chart's `pg_hba`.

The Frontend's own credential is separate and has one setting:
`analytics.starrocks.catalog.fePasswordSecretName`. Both provisioning Jobs and
the application (EventWriter Stream Load and the MyXQL reader) authenticate as
that same `root` account, so setting it once covers all three. Leave it empty
only for a passwordless Frontend.

The upstream `operator.yaml` is not restricted-PSS compatible. On carverauto an
unlabeled namespace enforces `restricted:latest`, so a raw apply creates the
Deployment and then ReplicaSet `FailedCreate` with no pods:

```
unrestricted capabilities (container "manager" must set
  securityContext.capabilities.drop=["ALL"]),
seccompProfile (pod or container "manager" must set
  securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

`values.yaml` sets those two fields. Do not install from the raw GitHub manifest.

## Install

Same manifests on both **lab** kube contexts: `carverauto` and `farm01`. Pass
`--context` / `--kube-context` for each; do not assume the current context.

CRDs are cluster-scoped and applied once per cluster, from the same operator
tag as the chart. The operator chart does not ship them.

```bash
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update starrocks

for ctx in carverauto farm01; do
  kubectl --context "$ctx" apply -f \
    https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/v1.11.7/deploy/starrocks.com_starrocksclusters.yaml
  kubectl --context "$ctx" apply -f k8s/starrocks/namespace.yaml
  helm upgrade --install kube-starrocks-operator starrocks/operator \
    --kube-context "$ctx" \
    --namespace starrocks \
    --version 1.11.7 \
    -f k8s/starrocks/values.yaml
  helm_files="-f k8s/starrocks/values-cluster.yaml"
  if [ "$ctx" = carverauto ]; then
    helm_files="$helm_files -f k8s/starrocks/values-cluster-shared-data.yaml"
  fi
  helm upgrade --install starrocks-lab starrocks/starrocks \
    --kube-context "$ctx" \
    --namespace starrocks \
    --version 1.11.7 \
    $helm_files
done
```

`run_mode` is fixed at first FE start. Switching carverauto from shared-nothing
to shared-data requires uninstalling `starrocks-lab` and deleting FE/BE PVCs
before the overlay install. Warehouse rows are rebuilt from JetStream/EventWriter;
do not point this overlay at the CNPG Barman bucket.

If the operator was already created with `kubectl apply -f .../operator.yaml`,
the first Helm install has to steal server-side field ownership from kubectl
as well as the Helm release annotations:

```bash
helm upgrade --install kube-starrocks-operator starrocks/operator \
  --kube-context "$ctx" \
  --namespace starrocks \
  --version 1.11.7 \
  -f k8s/starrocks/values.yaml \
  --take-ownership --force-conflicts --server-side=true
```

## Verify

```bash
for ctx in carverauto farm01; do
  echo "== $ctx =="
  kubectl --context "$ctx" -n starrocks get deploy,pods
  kubectl --context "$ctx" -n starrocks rollout status deploy/kube-starrocks-operator
done
```

Expect `kube-starrocks-operator` `1/1 Running`. Shared-nothing (farm01):
`lab-fe-0..2`, `lab-be-0..2` Ready. Shared-data (carverauto overlay):
`lab-fe-0..2`, `lab-cn-0..2` Ready. An empty operator pod list with a
Deployment present is the restricted-PSS failure above; check ReplicaSet events.

```bash
kubectl --context "$ctx" -n starrocks get svc lab-fe-service
# in-cluster: mysql -h lab-fe-service.starrocks.svc -P 9030 -uroot
```

## Schema

Nothing here is applied by hand. When `analytics.starrocks.enabled` is true,
core creates and upgrades the warehouse schema at startup
(`ServiceRadar.Analytics.StarRocks.SchemaMigrator`), on every Helm install,
Helm upgrade and Compose `up`:

- It waits for a live backend or compute node, then applies each file under
  `elixir/serviceradar_core/priv/starrocks/` whose version is not yet recorded
  in `<database>.schema_migrations`, in order.
- The files pin the database `serviceradar` and `replication_num` 3. The
  migrator retargets them to `analytics.starrocks.database`, and lowers
  replication to the number of live backends on a shared-nothing warehouse
  with fewer than three.
- Replicas that start together are serialised by a PostgreSQL advisory lock.
- A warehouse created before the ledger existed is adopted: CREATEs are
  `IF NOT EXISTS`, the rollup rebuild drops before it creates, and an
  `ADD COLUMN` whose column already exists is skipped.
- A failure is logged as `StarRocks schema not migrated, retrying in ...` and
  retried with backoff; the failed version is not recorded, so the next
  attempt resumes at it.

To see what a warehouse has:

```sql
SELECT version, name, applied_at FROM serviceradar.schema_migrations ORDER BY version;
```

A warehouse created before daily partitioning is rebuilt by core itself.
StarRocks cannot add partitioning or change a primary key with `ALTER`, so at
startup core copies each unpartitioned table onto a partitioned one beside it,
swaps the two, and drops the old one, while the warehouse keeps serving and
taking writes. Nothing is run by hand. Migration `0017`, which creates the
day-partitioned hourly rollups, waits for the rebuild; earlier migrations do
not. Every table is copied before any old table is dropped, so peak storage is
about twice the in-retention warehouse. A failure is logged as
`StarRocks partition rebuild of <table> failed` and retried on the migrator's
backoff, continuing from the days already copied; retention logs
`is not range partitioned` for a table until its rebuild completes. A fresh
warehouse is partitioned from `0001` and is not affected.

`cutoverDatasets` defaults to empty, so metric, log and event panels stay on
CNPG throughout; the NetFlow panel does not fall back -- it is refused with a
warehouse-required error until `flows` is cut over to a populated warehouse.

## Host sysctl

`vm.max_map_count` and `vm.overcommit_memory` are not namespaced. They cannot
be set in a pod `securityContext.sysctls`; they have to be set on the node.
CPU `limits` and StarRocks `mem_limit` are the opposite: those belong in the
`StarRocksCluster` spec, not on the host.

Applied on every untainted worker (carverauto `k8s-cp{2,3}-worker{1,2,3}`,
farm01 `k8s-cp{2,3,4}-worker{1,2,3}`) as `/etc/sysctl.d/99-starrocks.conf`:

```
vm.max_map_count = 2000000
vm.overcommit_memory = 1
```

That file sorts after Ubuntu `10-map-count.conf` (1048576) and
`99-kubernetes.conf` (1048575). `overcommit_memory` was already 1 on these
nodes (kubelet drop-in); the file keeps it. Root SSH is disabled; apply as
`mfreeman` with passwordless sudo.

Skipped: control-plane (NoSchedule), CNPG-dedicated, GPU (`nvidia.com/gpu`).
StarRocks cannot schedule there. New VMs from `gitops/VMs/setup-new-VM.sh`
still ship `vm.max_map_count=1048575` until that template is bumped or this
drop-in is copied.

### SaaS on Akamai LKE (not this directory)

Hosted ServiceRadar is LKE. Those workers are recycled Linodes (autoscale,
Kubernetes upgrades, "Recycle pool nodes"): an `/etc/sysctl.d` drop-in does
not survive. The LKE node-pool API only sets plan, count, labels, taints, and
autoscaler -- there is no GKE `linuxNodeConfig.sysctl` / AKS `vmMaxMapCount`.

`vm.max_map_count` is not namespaced, so the StarRocks chart `sysctls: []`
field cannot set it. On LKE the setting is a privileged DaemonSet in
`kube-system` (not the `restricted` `starrocks` namespace) that runs
`sysctl -w` against the host PID namespace on every new node. That manifest
is SaaS-cluster work; it is not applied to carverauto or farm01.

## Cluster CRs

Lab shared-nothing cluster lives in `starrocks` with `enforce: baseline`.
Do not apply the upstream `starrocks-fe-and-be.yaml` (`:latest`, 4 CPU / 8Gi,
1Ti BE disks). Do not put the CR in carverauto `demo` (Kyverno copyfail
seccomp) or farm01 `serviceradar`.

## Pins

| Item | Value |
| --- | --- |
| Helm repo | `https://starrocks.github.io/starrocks-kubernetes-operator` |
| Operator chart | `starrocks/operator` `1.11.7` |
| Cluster chart | `starrocks/starrocks` `1.11.7` |
| Operator image | `starrocks/operator:v1.11.7` |
| FE/BE/CN image | `starrocks/fe-ubuntu:3.5.21`, `starrocks/be-ubuntu:3.5.21`, `starrocks/cn-ubuntu:3.5.21` |
| CRD | `starrocksclusters.starrocks.com` from operator tag `v1.11.7` |
| Namespace | `starrocks`, PSS `baseline` (audit/warn `restricted`) |
| Profile | farm01: 3 FE + 3 BE shared-nothing; carverauto: 3 FE + 3 CN shared-data |
