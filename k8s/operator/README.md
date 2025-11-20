# CNPG Operator Snapshot (v1.24.1)

This directory contains a snapshot of the CloudNativePG operator deployment (controller/webhooks) pinned to v1.24.1, targeted at the `cnpg-system` namespace.

We do **not** currently include this operator in the demo kustomize overlays or Helm chart. It remains a cluster-scoped prerequisite; install it once per cluster using Helm (recommended):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg-operator cnpg/cloudnative-pg -n cnpg-system --create-namespace --skip-crds
```

This snapshot is kept here for reference and potential future bundling; it should not be applied directly without reconciling RBAC/webhook resources for your cluster.
