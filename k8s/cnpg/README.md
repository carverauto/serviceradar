# cloud-native postgres

## Auth Setup

After you create the auth secrets you can rely on the operator to provision
application users and databases automatically. Apply the supporting secrets and
cluster definitions before deploying workloads that depend on them:

```bash
kubectl apply -f k8s/cnpg/cnpg-auth.yaml
kubectl apply -f k8s/cnpg/spire-db-credentials.yaml
kubectl apply -f k8s/cnpg/new-pg-cluster.yaml
```

The `managed.roles` section ensures the `kratos` and `spire` accounts always
exist with the provided passwords, while `managed.databases` keeps the `spire`
database owned by the correct role. No manual `psql` steps required.
