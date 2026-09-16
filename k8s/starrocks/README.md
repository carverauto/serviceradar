# StarRocks operator

This directory is the **lab** install: kube contexts `carverauto` and `farm01`.
Those clusters are self-managed k3s used for ServiceRadar development and test.
They are not the SaaS control plane.

The cloud/SaaS product runs on **Akamai LKE**. Do not copy lab node procedures
(SSH, `/etc/sysctl.d`, `gitops/VMs/setup-new-VM.sh`) onto LKE workers. Hosted
StarRocks is the shared-data profile from
`openspec/changes/add-starrocks-telemetry-analytics` (object storage + CN
cache); that chart/DaemonSet work belongs with the SaaS cluster, not here.

Cluster-scoped operator, pinned to chart/operator **1.11.7**. The lab
`StarRocksCluster` is shared-nothing FE+BE (`values-cluster.yaml`), pinned to
StarRocks **3.5.21**. Hosted shared-data (CN + object storage) is not this
directory.

The CNPG JDBC catalog (`cnpg_platform`) is opt-in and off by default. FE/BE
expect the pinned PostgreSQL JDBC driver at
`file:///opt/starrocks/jdbc/postgresql.jar` (checksum in
`third_party/jdbc/postgresql.pin`). `values-cluster.yaml` has a checksummed
alpine initContainer that mounts an emptyDir `jdbc` volume (chart 1.11.7
ignores extra storageVolumes; emptyDir is the extra-volume API) so FE/BE
share `file:///opt/starrocks/jdbc/postgresql.jar`. The initContainer
re-fetches the pinned jar (IPv4 wget) when the checksum is missing.
Nodes that cannot resolve repo1.maven.org will CrashLoop the init
container; do not roll those until the jar is available in-cluster.
Demo CNPG now has an additive NetworkPolicy allowing namespace
`starrocks` on 5432. Lab FE has `cnpg_platform` (infra secret
`serviceradar-starrocks-catalog`, not in git). Helm default catalog stays
off; `values-demo.yaml` enables it with empty cutover. Do not let the
Frontend download Maven at catalog-create time.

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
  helm upgrade --install starrocks-lab starrocks/starrocks \
    --kube-context "$ctx" \
    --namespace starrocks \
    --version 1.11.7 \
    -f k8s/starrocks/values-cluster.yaml
done
```

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

Expect `kube-starrocks-operator` `1/1 Running` and FE/BE pods
`lab-fe-0..2`, `lab-be-0..2` Ready. An empty operator pod list with a
Deployment present is the restricted-PSS failure above; check ReplicaSet events.

```bash
kubectl --context "$ctx" -n starrocks get svc lab-fe-service
# in-cluster: mysql -h lab-fe-service.starrocks.svc -P 9030 -uroot
```

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
| FE/BE image | `starrocks/fe-ubuntu:3.5.21`, `starrocks/be-ubuntu:3.5.21` |
| CRD | `starrocksclusters.starrocks.com` from operator tag `v1.11.7` |
| Namespace | `starrocks`, PSS `baseline` (audit/warn `restricted`) |
| Profile | 3 FE + 3 BE, ClusterIP, `local-path` PVCs |
