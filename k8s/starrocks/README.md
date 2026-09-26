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
curl initContainer that mounts an emptyDir `jdbc` volume (chart 1.11.7
ignores extra storageVolumes; emptyDir is the extra-volume API) so FE/BE
share `file:///opt/starrocks/jdbc/postgresql.jar`. The initContainer
re-fetches the pinned jar when the checksum is missing. It uses curl, not
BusyBox wget: repo1.maven.org resolves to IPv6 first, and BusyBox wget does
not fall back to IPv4, so on a cluster without IPv6 egress every retry fails.
Nodes that cannot reach repo1.maven.org will CrashLoop the init
container; do not roll those until the jar is available in-cluster.
Demo CNPG now has an additive NetworkPolicy allowing namespace
`starrocks` on 5432. Lab FE has `cnpg_platform`, created by the chart's
catalog Job from a generated reader Secret. Helm default catalog stays
off; `values-demo.yaml` enables it. Do not let the Frontend download
Maven at catalog-create time.

The catalog connects to CNPG as `serviceradar_starrocks_reader`. Two things
converge that role, so there is nothing to grant by hand:

| Object | Granted |
| --- | --- |
| schema `platform` | `USAGE` |
| `platform.netflow_local_cidrs_catalog` | `SELECT` |
| `platform.ocsf_devices` | `SELECT (uid, uid_alt, hostname, name, ip)` |
| `platform.device_identifiers` | `SELECT (device_id, identifier_type, identifier_value)` |
| `platform.discovered_interfaces` | `SELECT (device_id, device_ip)` |
| `platform.device_interface_addresses_catalog` | `SELECT (device_id, ip)` |
| `platform.device_inventory_aliases_catalog` | `SELECT (uid, uid_alt, alias)` |
| `platform.device_alias_states` | `SELECT (device_id, alias_type, state, alias_value)` |
| `platform.netflow_exporter_cache` | `SELECT (device_uid, sampler_address, exporter_name)` |
| `platform.netflow_interface_cache` | `SELECT (sampler_address, if_index, if_name, if_speed_bps)` |
| `platform.ip_geo_enrichment_cache` | `SELECT (ip, country_iso2, expires_at)` |

Two of those are views, not tables. A PostgreSQL `text[]` and a `jsonb` both
reach StarRocks 3.5.21 as `UNKNOWN_TYPE`, and a query that names such a column
is refused at analysis, so CNPG flattens what the device lookups need:
`device_interface_addresses_catalog` is one row per interface address, and
`device_inventory_aliases_catalog` is one row per name the inventory knows a
device by (it exposes five named metadata keys, never the document). Core
migration `20260921130000_grant_starrocks_reader_device_identity` creates both
views and issues the grants the device lookups added -- the two views,
`device_identifiers`, `discovered_interfaces`, and `uid_alt`/`name` on
`ocsf_devices` -- guarded on the role existing, the way the create-role
migration below guards its own.

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

The Frontend's own credential is separate: the `root` account, protected by a
password that lives in one value held in three places -- the operator's
initPassword Secret, the ServiceRadar chart's
`analytics.starrocks.catalog.fePasswordSecretName` Secret, and the live
account. Both provisioning Jobs and the application (EventWriter Stream Load
and the MyXQL reader) authenticate as that same `root` account. The chart
refuses to render with StarRocks enabled and no Secret named; there is no
passwordless mode. See [Frontend root password](#frontend-root-password).

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

**This block is for a cluster that does not exist yet, or one that already has
a root password.** `values-cluster.yaml` enables `initPassword`, which makes
every FE, BE and CN pod log in as root with the password Secret when it
starts. Upgrading a Frontend that still has NO password with it leaves every
restarted pod unable to rejoin. An existing passwordless installation follows
[Existing installation](#existing-installation) instead, in that order.

Before the loop, for each cluster: label the ServiceRadar namespace (see
[Network policy](#network-policy)) and create the root-password Secret in
`starrocks` and its twin in the ServiceRadar namespace
([Fresh install](#fresh-install), steps 1 and 2). The FE, BE and CN pods do not
start until the Secret exists.

```bash
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update starrocks

for ctx in carverauto farm01; do
  kubectl --context "$ctx" apply -f \
    https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/v1.11.7/deploy/starrocks.com_starrocksclusters.yaml
  kubectl --context "$ctx" apply -f k8s/starrocks/namespace.yaml
  kubectl --context "$ctx" apply -f k8s/starrocks/network-policy.yaml
  kubectl --context "$ctx" -n starrocks get secret starrocks-root-password >/dev/null
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

## Frontend root password

The chart `starrocks/starrocks` creates the Frontend's `root` account with no
password unless `initPassword` is enabled, and a passwordless `root` is
administrative access to the whole warehouse for anything that reaches port
9030. `values-cluster.yaml` therefore enables it, reading the password from a
Secret the chart does not create:

```yaml
initPassword:
  enabled: true
  isInstall: true
  passwordSecret: starrocks-root-password   # namespace starrocks, key `password`
```

One value, held in three places that must stay byte-identical:

| Where | What | Read by |
| --- | --- | --- |
| Secret `starrocks-root-password` in `starrocks` | key `password` | the operator: injected as `MYSQL_PWD` into every FE, BE and CN pod; the chart's init Job |
| Secret named by `analytics.starrocks.catalog.fePasswordSecretName` in the ServiceRadar namespace (for example `serviceradar-starrocks-fe`) | key `fePasswordSecretKey`, default `password` | core, web-ng, the catalog and storage-volume Jobs |
| the live `root` account | its password | the Frontend |

The operator's `MYSQL_PWD` is not decoration. The FE, BE and CN start-up
scripts use it to log in as `root` and register with the leader FE every time
a pod starts. If the Secret and the live password differ -- including a Secret
that holds a password while the account still has none -- a restarted FE, BE or
CN cannot rejoin, and the cluster degrades one pod restart at a time. The same
holds on the ServiceRadar side: a password sent to an account that has none is
refused just like a wrong one.

Two rules follow. Never change one of the three without the other two, in the
order below. And never write the value with a trailing newline: create the
Secrets with `--from-file` from a file written by `tr -d '\n'`, as below, not
from `echo` output or an editor.

The ServiceRadar chart fails to render when `analytics.starrocks.enabled` is
true and `analytics.starrocks.catalog.fePasswordSecretName` is empty. There is
no setting that turns that off, deliberately.

### Fresh install

1. Generate the password into a local file only you can read. It never goes on
   a command line, into shell history, or into a values file:

   ```bash
   ( umask 077; openssl rand -hex 32 | tr -d '\n' > starrocks-root-password )
   ls -l starrocks-root-password   # -rw------- ; 64 bytes
   ```

2. Create both Secrets from that one file, then prove they match it without
   printing the value:

   ```bash
   kubectl -n starrocks create secret generic starrocks-root-password \
     --from-file=password=starrocks-root-password
   kubectl -n <serviceradar-namespace> create secret generic serviceradar-starrocks-fe \
     --from-file=password=starrocks-root-password

   sha256sum < starrocks-root-password
   kubectl -n starrocks get secret starrocks-root-password \
     -o jsonpath='{.data.password}' | base64 -d | sha256sum
   kubectl -n <serviceradar-namespace> get secret serviceradar-starrocks-fe \
     -o jsonpath='{.data.password}' | base64 -d | sha256sum
   ```

   All three digests must be the same. If the Secrets come from a secret
   manager rather than `kubectl create`, they must still hold exactly these
   bytes.

3. Install the operator and the cluster as in [Install](#install). A first
   `helm install` of `starrocks-lab` renders the one-shot Job `lab-initpwd`,
   which sets the password once the leader FE answers:

   ```bash
   kubectl -n starrocks logs job/lab-initpwd   # "Successfully modified password"
   ```

   `isInstall: true` only has effect on a first `helm install`. A renderer that
   reports every run as an install -- `helm template | kubectl apply`, Argo CD
   -- must pass `initPassword.isInstall=false` after the first install.

4. Set `analytics.starrocks.catalog.fePasswordSecretName:
   serviceradar-starrocks-fe` in the ServiceRadar values and install
   ServiceRadar. Then delete the local file, or move it into your password
   store.

### Existing installation

For a cluster that has been running with a passwordless `root`. The order is
the point: every step that changes one of the three places is followed at once
by the steps that bring the other two into line. Between steps 4 and 6
ServiceRadar cannot authenticate; failed Stream Loads are logged as
`StarRocks warehouse load failed; batch quarantined for replay` and replayed
after step 6, and warehouse-backed reads fail until then. Run steps 4, 5 and 6
back to back.

Placeholders: `<serviceradar-namespace>` is the ServiceRadar release's
namespace; the FE pods are `lab-fe-0..2` and the release `starrocks-lab`, as
installed from this directory.

1. **Generate the password into a local file** (mode 600, no trailing newline):

   ```bash
   ( umask 077; openssl rand -hex 32 | tr -d '\n' > starrocks-root-password )
   ls -l starrocks-root-password
   ```

2. **Create both Secrets from that file**, and compare the digests, exactly as
   in [Fresh install](#fresh-install) step 2. Creating them changes nothing
   yet: nothing reads either Secret until steps 5 and 6.

3. **Make the ServiceRadar release name the Secret, and check what will
   actually be deployed.** Set
   `analytics.starrocks.catalog.fePasswordSecretName: serviceradar-starrocks-fe`
   in the values or overlay the release is deployed from. Do not let it roll
   yet (step 6): if the release syncs automatically, pause that first.

   Verify the RENDERED Deployment, not the values file and not a GitOps
   Application spec. Parameter overrides are applied after the values files and
   silently win: for Argo CD that includes `spec.source.helm.parameters` and a
   `.argocd-source-<app>.yaml` file inside the chart directory, which Argo CD
   reads from the chart source. Render the way the deployer does:

   ```bash
   # Helm CLI release: the same chart, values files and --set flags as the release.
   helm template serviceradar ./helm/serviceradar -n <serviceradar-namespace> \
     -f <values files the release uses> \
     | grep -A4 'name: SERVICERADAR_STARROCKS_PASSWORD'

   # Argo CD: the desired manifests Argo CD itself rendered.
   argocd app manifests <app> \
     | grep -A4 'name: SERVICERADAR_STARROCKS_PASSWORD'
   ```

   Expect two matches (serviceradar-core and serviceradar-web-ng), each with
   `secretKeyRef` name `serviceradar-starrocks-fe`. No match, or a render that
   fails with `fePasswordSecretName is required`, means the value is not
   reaching the chart.

4. **Set the Frontend password by SQL, fed on stdin.** `printf` is a shell
   builtin, so the value appears in no process argument list. `env -u
   MYSQL_PWD` guarantees a passwordless login even if a pod already has
   `MYSQL_PWD` injected. Run it against the leader FE:

   ```bash
   kubectl -n starrocks exec lab-fe-0 -- env -u MYSQL_PWD \
     mysql -h 127.0.0.1 -P 9030 -u root -e 'SHOW FRONTENDS\G' \
     | grep -E '^ *(Name|Role):'          # pick the pod whose Role is LEADER

   printf "SET PASSWORD = PASSWORD('%s');\n" "$(cat starrocks-root-password)" \
     | kubectl -n starrocks exec -i <leader-fe-pod> -- env -u MYSQL_PWD \
         mysql -h 127.0.0.1 -P 9030 -u root
   ```

   Confirm at once that the old login is gone and the new one works:

   ```bash
   kubectl -n starrocks exec lab-fe-0 -- env -u MYSQL_PWD \
     mysql -h 127.0.0.1 -P 9030 -u root -e 'SELECT 1'
   # expect: ERROR 1045 (28000): Access denied for user 'root' ...
   kubectl -n starrocks exec -i lab-fe-0 -- sh -c \
     'read -r p; MYSQL_PWD="$p" exec mysql -h 127.0.0.1 -P 9030 -u root -e "SELECT 1"' \
     < starrocks-root-password
   # expect: 1
   ```

   From here until step 5 finishes, a StarRocks pod that restarts cannot
   rejoin, because it still starts without `MYSQL_PWD`. Go straight on.

5. **Upgrade the cluster release with initPassword enabled and `isInstall`
   false.** Pass the same files the release was installed with, including the
   shared-data overlay where it applies:

   ```bash
   helm upgrade starrocks-lab starrocks/starrocks \
     --namespace starrocks --version 1.11.7 \
     -f k8s/starrocks/values-cluster.yaml \
     --set initPassword.isInstall=false
   ```

   This adds `MYSQL_PWD` to the FE, BE and CN specs, so the operator rolls
   every StarRocks pod; each one now registers with the password. Confirm the
   wiring and wait for the roll:

   ```bash
   kubectl -n starrocks get sts lab-fe \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MYSQL_PWD")].valueFrom.secretKeyRef.name}{"\n"}'
   # expect: starrocks-root-password   (same for lab-be, or lab-cn on shared-data)
   kubectl -n starrocks get pods -w
   ```

6. **Roll ServiceRadar** with the change from step 3 (`helm upgrade`, or
   resume the sync). It depends only on step 4, so it need not wait for the
   StarRocks roll to finish. Then check the LIVE Deployments:

   ```bash
   for d in serviceradar-core serviceradar-web-ng; do
     kubectl -n <serviceradar-namespace> get deploy "$d" \
       -o jsonpath='{.metadata.name}{" "}{.spec.template.spec.containers[0].env[?(@.name=="SERVICERADAR_STARROCKS_PASSWORD")].valueFrom.secretKeyRef.name}{"\n"}'
   done
   kubectl -n <serviceradar-namespace> rollout status deploy/serviceradar-core
   kubectl -n <serviceradar-namespace> rollout status deploy/serviceradar-web-ng
   ```

   Each line must end in `serviceradar-starrocks-fe`.

7. **Verify, against the state after both rolls finished.** Each check has a
   failure answer; read what it printed.

   ```bash
   # Passwordless login is refused (on every FE, not just one).
   for i in 0 1 2; do
     kubectl -n starrocks exec lab-fe-$i -- env -u MYSQL_PWD \
       mysql -h 127.0.0.1 -P 9030 -u root -e 'SELECT 1' 2>&1 | head -1
   done
   # expect three times: ERROR 1045 (28000) ...  -- a "1" means it still logs in

   # The cluster re-formed with the password (the pods' own MYSQL_PWD).
   kubectl -n starrocks exec lab-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root \
     -e 'SHOW FRONTENDS\G SHOW BACKENDS\G SHOW COMPUTE NODES\G' | grep -c 'Alive: true'
   # expect: FE replicas + BE (or CN) replicas

   # The application has no authentication errors since its rollout finished.
   # Pick --since so the window starts AFTER step 6 completed.
   for app in serviceradar-core serviceradar-web-ng; do
     kubectl -n <serviceradar-namespace> logs -l app=$app --since=10m --prefix \
       | grep -ciE 'access denied|1045|StarRocks warehouse load failed'
   done
   # expect: 0 and 0 -- on anything else, print the lines (drop -c) and read them

   # Rows are still landing: run twice a few minutes apart; the value must
   # advance and be later than the step 6 rollout.
   kubectl -n starrocks exec lab-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root \
     -e 'SELECT MAX(`timestamp`) FROM serviceradar.timeseries_metrics; SELECT MAX(`time`) FROM serviceradar.ocsf_network_activity'
   ```

   Then delete the local password file or move it into your password store.

### Rollback

The three places move back together, in the same order. If ServiceRadar or the
cluster misbehaves after the change, the usual fix is to bring the lagging
place into line (a Secret with the wrong bytes, a render that lost the
parameter), not to remove the password. If you must return to a passwordless
Frontend -- which reopens the hole -- clear the password and roll the cluster
release back together, then roll ServiceRadar back to its previous revision
(the current chart refuses to render a passwordless Frontend):

```bash
# 1. Clear the password. The first stdin line is the current password, read
#    into MYSQL_PWD inside the pod; the rest of stdin is the SQL.
{ cat starrocks-root-password; printf '\n%s\n' "SET PASSWORD = PASSWORD('');"; } \
  | kubectl -n starrocks exec -i lab-fe-0 -- sh -c \
      'read -r p; MYSQL_PWD="$p" exec mysql -h 127.0.0.1 -P 9030 -u root'
# 2. Roll the cluster release back to before step 5 (removes MYSQL_PWD; the
#    operator rolls every StarRocks pod).
helm -n starrocks history starrocks-lab
helm -n starrocks rollback starrocks-lab <revision-before-step-5>
# 3. Roll ServiceRadar back to before step 6.
helm -n <serviceradar-namespace> rollback serviceradar <revision-before-step-6>
```

Until step 2 has rolled every pod, a StarRocks pod that restarts carries a
`MYSQL_PWD` the account no longer has and cannot rejoin; run 1 and 2 back to
back. A GitOps-managed release is rolled back by reverting the change in its
source, with the same ordering.

### Changing the password later

Same lockstep: write the new value to a file (step 1), set it by SQL logging
in with the OLD one, update BOTH Secrets from the new file (`kubectl create
secret ... --dry-run=client -o yaml | kubectl apply -f -`), then restart the
StarRocks pods (`kubectl -n starrocks rollout restart sts/lab-fe sts/lab-be`,
or `sts/lab-cn`) and ServiceRadar. A Secret change reaches a running pod's
`MYSQL_PWD` only when the pod restarts, so a pod that restarts on its own
before the Secret is updated cannot rejoin.

## Network policy

`network-policy.yaml` fences ingress to the `starrocks` namespace. It selects
every pod there, so everything not admitted is dropped:

- any traffic between pods inside `starrocks` (FE, BE, CN, the operator, the
  init Job), on any port;
- from a namespace labelled `serviceradar.carverauto.dev/starrocks-client:
  "true"`, TCP 9030 (FE MySQL protocol), 8030 (FE HTTP, the Stream Load entry
  point) and 8040 (BE/CN HTTP: Stream Load redirects the client to a backend's
  own address on this port, so without it every EventWriter write fails while
  reads keep working).

Label the ServiceRadar namespace FIRST. Applying the policy before the label
cuts the application off the warehouse, and the symptom is connection
timeouts, not an authentication error:

```bash
kubectl label namespace <serviceradar-namespace> \
  serviceradar.carverauto.dev/starrocks-client=true
kubectl apply -f k8s/starrocks/network-policy.yaml
```

The ports are the ones `values-cluster.yaml` sets (`query_port`, `http_port`,
`webserver_port`); change both files together. Anything else that must reach
the warehouse -- a Prometheus scraping FE `:8030/metrics` or BE `:8040/metrics`
from its own namespace, say -- needs the label on its namespace too, which also
grants it 9030. Egress is not restricted: the FE and BE reach CNPG for the JDBC
catalog, and CN reaches object storage on shared-data. Kubelet probes come from
the node, which most CNIs admit regardless of NetworkPolicy; after applying,
confirm the StarRocks pods stay Ready on yours.

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
# in-cluster: mysql -h lab-fe-service.starrocks.svc -P 9030 -uroot -p
# (inside an FE/BE/CN pod MYSQL_PWD is already set; `env -u MYSQL_PWD` to test
# that a passwordless login is refused)
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

`0019` creates `mtr_traces` and `mtr_hops`, with the column names of the CNPG
tables of the same name, partitioned by day from the start, so the rebuild
never touches them. MTR is not shadowed: while `analytics.starrocks.enabled`
is true, EventWriter writes MTR traces and hops to these two tables only, and
a failed load is redelivered from JetStream rather than written to CNPG. Their
retention is `analytics.starrocks.retentionDays.mtr` (default 365), applied to
both tables.

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

## Logs and events parity check

The logs and events dialect was checked against a real StarRocks 3.5.21 and a
PostgreSQL holding the same synthetic rows (`host01.example.com`,
`192.0.2.0/24`), with the catalog reader holding exactly the grants above. The
SQL on each side was the SRQL compiler's own output for the same query.

- All 38 statements executed on StarRocks, including the anomaly rollup's
  boolean-valued derived columns, every catalog subquery, and the event device
  filter's non-equality join against the device's alias set. StarRocks refuses
  that test as a correlated subquery, which is how CNPG writes it; as a join
  inside an uncorrelated `id IN (...)` the planner accepts it.
- `rollup_stats:severity` (with and without a `service_name` LIKE),
  `rollup_stats:anomaly_findings`, the three `finding_rollup` drill-downs,
  `event_type`, `source`, `hostname`, `severity_match:any`, the log
  `device_id` filter in both polarities, and the text filters (mixed-case
  LIKE, and `!=` / `NOT IN` / `NOT LIKE` over NULL rows) returned the same
  rows or counters on both engines.
- `!device_id:` on events returned the same rows on both engines for a
  canonical uid, a raw id and a device with no events. CNPG's canonical
  equality is NULL, not FALSE, for an event that carries neither canonical
  path, so both engines return only the events known to be about another
  device; that arm is deliberately left three-valued here, and the alias and
  scan arms are two-valued as CNPG's are.
- `device_id:` on events found, on both engines, an event that names the
  device only inside an observable, one whose hostname differs from the
  inventory's in case, and one whose only mention is `HOSTNAME=<alias>`
  inside a label string. The same alias under a key CNPG does not accept
  (`owner=`) matched on neither. An alias containing `_` matched only itself.
- `other:true` on flow stats (one group key, the three-key Sankey shape, and
  two aggregates with a limit above the group count) returned the same rows
  in the same order on both engines, including which of two tied groups falls
  on each side of the cut. The top rows plus the tail summed to the ungrouped
  total, and no tail row was emitted when nothing was left over. CNPG answers
  the one-key form from its hourly talkers aggregate, which the comparison
  stood in for with a view over the same rows.
- `device_id:` on events differs from CNPG in three ways. The first two are
  rows the warehouse returns and CNPG does not; the third is the reverse:
  - Inside CNPG's alias `EXISTS`, the unqualified `metadata` resolves to the
    device row's own `metadata` column rather than the event's, so CNPG does
    not find an event that names the device only in its metadata -- a
    hostname, a `uid_alt`, or a dotted key such as `host.name`. The warehouse
    reads the event's metadata and does find it.
  - CNPG requires one of its identity or host keys somewhere ahead of the
    alias in the document text. For a quoted JSON string the warehouse
    requires only that the alias appear as one, so an alias held under a key
    outside that list (`device.name`, for one) matches here and not on CNPG.
    The `key=value` form is held to CNPG's key list on both.
  - `dst_endpoint` is not stored in the warehouse, and `src_endpoint` only as
    `src_endpoint_ip`. An event that names the device only inside
    `dst_endpoint`, or in `src_endpoint` under a key other than `ip`, is found
    by CNPG and not here. This is the one case the warehouse misses.

### Event row shape

An event row read from the warehouse reaches its caller in CNPG's shape:
`metadata`, `unmapped`, `device` and `observables` are stored as JSON text and
decoded back to maps and lists where warehouse rows are built
(`ServiceRadar.Analytics.StarRocks.EventDocuments`, used by the web API's JSON
and Arrow paths and by `SRQLRunner`). A NULL document stays nil, and one that
does not decode is left as text rather than failing the row.

The event detail page also reads `actor`, `raw_data`, `src_endpoint`,
`dst_endpoint` and `enrichment`, which the warehouse does not store. Those
keys are absent from a warehouse row, the page falls back to its empty
defaults, and the sections built from them render empty where CNPG fills them
in. Nothing raises, but it is a visible difference to settle before events are
cut over.
