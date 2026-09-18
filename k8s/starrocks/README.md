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
`starrocks` on 5432. Lab FE has `cnpg_platform` (infra secret
`serviceradar-starrocks-catalog`, not in git). Helm default catalog stays
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
the role into the cluster manifest with `login: true` and the password from
`analytics.starrocks.catalog.readerPasswordSecret`, reconciled continuously so
it survives failover. Use that same password in the `jdbcUri` baked into the
catalog secret. Neither the migration nor the Job ever sets login or password.

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

Every file under `elixir/serviceradar_core/priv/starrocks/` qualifies its
statements with the database name `serviceradar`. Helm
`analytics.starrocks.database` retargets every reader and Stream Load, so when
it is not the default, rewrite the DDL the same way the Compose
`starrocks-init` service does before applying it -- `retarget` below is the
same pair of substitutions that service runs, and applies to ANY of these
files, not just the ones in the fresh-warehouse apply:

```bash
ns=demo   # the release namespace
db=$(helm get values serviceradar -n "$ns" -o json |
  jq -r '.analytics.starrocks.database // "serviceradar"')
schema=elixir/serviceradar_core/priv/starrocks

retarget() {
  sed -e "s/EXISTS serviceradar;/EXISTS $db;/" -e "s/serviceradar\./$db./g" "$@"
}

# Fresh warehouse: the CREATEs, plus the flow-rollup rebuild.
retarget "$schema"/000[1-5]_*.sql "$schema"/0016_*.sql |
  mysql -h ... -P 9030 -uroot
```

`0006`-`0015` are one-shot `ALTER`s for warehouses created before those columns
existed; apply them individually through `retarget`, and expect a failure if
the column is already there. `0016` is different: it DROPs and recreates
`ocsf_network_activity_hourly`, so it is safe to re-run and is REQUIRED on any
warehouse whose rollup predates sampling-weighted totals -- the SRQL compiler
now reads that view for whole-hour flow charts, and the old column set has no
`bytes_total` at all.

The chart has no schema-apply Job, so nothing creates these tables for you.
Core's MyXQL pool opens `analytics.starrocks.database` directly, and Stream
Load PUTs to `/api/<database>/...`, so a mismatch between the applied DDL and
that value leaves the warehouse empty while the deployment looks healthy --
`cutoverDatasets` defaults to empty, so the UI stays on CNPG throughout.

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
