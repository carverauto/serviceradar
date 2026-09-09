# CNPG Operator Snapshot and Upgrade Record

This directory contains a snapshot of the CloudNativePG operator deployment
(controller/webhooks) targeted at the `cnpg-system` namespace.

We do **not** currently include this operator in the demo kustomize overlays or Helm chart. It remains a cluster-scoped prerequisite; install it once per cluster using Helm (recommended):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg-operator cnpg/cloudnative-pg -n cnpg-system --create-namespace
```

This snapshot is kept here for reference and potential future bundling; it should not be applied directly without reconciling RBAC/webhook resources for your cluster.

## Deployment record (reviewed for issue #221)

GitOps was rechecked on 2026-09-09 at
[revision `fd1ddc3`](https://github.com/carverauto/gitops/tree/fd1ddc3bbfadd40c2ac72c03bf4e9168c7dbdc29).
The [plugin manifest](https://github.com/carverauto/gitops/blob/fd1ddc3bbfadd40c2ac72c03bf4e9168c7dbdc29/k8s/cnpg-barman-cloud/base/kustomization.yaml)
records the plugin pin and mentions operator 1.27.1 in a comment; it does not
declare the operator release or its Helm chart version. No operator chart pin
was found in that review. GitOps therefore does not establish the installed
operator/chart versions, and the deployment compatibility verdict remains
conditional until the cluster owners confirm the current Helm release.

- **Unverified review baseline:** operator **1.27.1** via Helm chart
  `cloudnative-pg-0.26.1` (reported release `cnpg-operator` in `cnpg-system`,
  Helm-managed). Confirm both versions and management ownership before rollout.
- **Reviewed target:** operator **1.30.0** (released Jun 29, 2026) via Helm chart
  `cloudnative-pg-0.29.0`. Deployment status is unverified; the rollout belongs in a
  gitops change applied via Helm/Argo by the cluster owners -- never from this repo.
- **Cluster floor:** Kubernetes v1.34 (e.g. v1.34.4+k3s1), inside the 1.30.0
  supported range (1.34, 1.35, 1.36).
- **Companion plugin:** `plugin-barman-cloud` v0.13.0 (Argo app `cnpg-barman-cloud`),
  which requires operator >= 1.26 -- compatible with both 1.27.1 and 1.30.0.

## Conditional compatibility review: 1.27.1 -> 1.30.0

- Chart manifests use only `postgresql.cnpg.io/v1` (Cluster, Pooler,
  ScheduledBackup) -- all stable in 1.30.0.
- 1.30.0 makes the `cluster` reference immutable on Database, Pooler,
  Publication, Subscription, and ScheduledBackup via CEL validation. This chart
  renders those references from static release values and never retargets them,
  so the rule does not bite.
- In-tree `barmanObjectStore` (used by this chart only when
  `cnpg.backup.enabled=true`; default is `false`) is **deprecated but still
  functional in 1.30.0**. Upstream deferred removal to **1.31.0**, so the
  operator upgrade is not blocked -- but the chart backup path must migrate to
  the already-installed barman-cloud plugin (ObjectStore CR) before any 1.31
  upgrade. That migration is separate follow-up work, tracked against the 1.31
  removal notice.
- 1.30.0 defaults new clusters to PostgreSQL 18.4, matching this repo's PG18
  CNPG image base (`18.4-system-bookworm` in `MODULE.bazel`).
- No repo manifests reference the deprecated `status.latestGeneratedNode`
  field, and nothing depends on instance-serial monotonicity.
- Upgrade motivation beyond currency: 1.30.0 adds authenticated
  operator-to-instance-manager calls, which are not backported. `search_path`
  hardening and operator-side SCRAM-SHA-256 password encoding are also included
  in 1.29.2 and 1.28.4. See the
  [upstream upgrade notes](https://cloudnative-pg.io/docs/1.30/installation_upgrade/).

## Migration steps (for the gitops rollout, not this repo)

1. Upgrade the Helm release with its reviewed deployment values and
   `crds.create=true` so CRDs move with the operator. The chart manages CRDs
   through [Helm templates](https://github.com/cloudnative-pg/charts/blob/cloudnative-pg-v0.29.0/charts/cloudnative-pg/templates/crds/crds.yaml);
   `--skip-crds` does not control these templates. Version 1.30.0 adds CEL rules
   and new CRDs such as `DatabaseRole`. Base command (supply the deployment's
   values file when applying):
   `helm upgrade cnpg-operator cnpg/cloudnative-pg --version 0.29.0 -n cnpg-system`
2. Confirm every Cluster is healthy before starting, then wait for the operator
   Deployment and instance-manager upgrades to finish and re-check every Cluster.
   By default, the latter rolls PostgreSQL instances and ends with a switchover;
   applications must reconnect. Review the
   [upstream upgrade procedure](https://cloudnative-pg.io/docs/1.30/installation_upgrade/#upgrades)
   for supervised primary updates and in-place instance-manager updates.
3. Confirm the `cnpg-barman-cloud` Argo app still syncs (operator 1.30.0
   auto-reloads CNPG-i plugins on pod roll; no plugin bump required).
4. Before any future 1.31 upgrade: migrate `cnpg.backup` off in-tree
   `barmanObjectStore` onto the barman-cloud plugin.
