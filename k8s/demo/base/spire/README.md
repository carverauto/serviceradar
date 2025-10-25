# ServiceRadar Demo SPIRE Setup

Manifests under this directory bootstrap SPIFFE/SPIRE inside the demo Kubernetes namespace. They are **not** part of the default demo kustomization; apply them separately while we iterate on the onboarding workflow.

## Quick Start

1. **Create the database secret** (generate a password locally and populate the template—do not commit real secrets):

```bash
openssl rand -hex 24 > /tmp/spire-db-pass
kubectl create secret generic spire-postgres \
  --from-file=DB_PASSWORD=/tmp/spire-db-pass \
  --namespace spire
rm /tmp/spire-db-pass
# optional: if you prefer GitOps, copy pg-secret.yaml to a private repo,
# replace <REPLACE_WITH_RANDOM_PASSWORD>, and apply from there.
```

2. **Deploy SPIRE server + agent:**

```bash
kubectl apply -k k8s/demo/base/spire
```

3. **Create node registration entries** so the daemonset agents can authenticate back to the server:

```shell
kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://carverauto.dev/ns/spire/sa/spire-agent \
    -selector k8s_sat:cluster:carverauto-cluster \
    -selector k8s_sat:agent_ns:spire \
    -selector k8s_sat:agent_sa:spire-agent \
    -node
```

4. **Register workloads** (repeat for each namespace/service account that should receive an SVID):

```shell
kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://carverauto.dev/ns/default/sa/default \
    -parentID spiffe://carverauto.dev/ns/spire/sa/spire-agent \
    -selector k8s:ns:default \
    -selector k8s:sa:default
```

## Additional Assets

- `client-deployment.yaml`, `cert-certificate.yaml`, and related issuer manifests are provided for experimentation and are intentionally excluded from `kustomization.yaml`. Apply or customize them manually if you need TLS automation beyond the demo defaults.
- `test.sh` contains a basic sanity check that fetches an SVID from within the cluster.
- The demo server `Service` is a `NodePort` exposing gRPC on `8081`. Ensure firewall rules (or a load balancer/ingress of your choice) allow edge sites to reach that port plus the HTTP health port `8080` if you monitor readiness externally.
- For Helm or other packaging flows, mirror the secret-generation step above (for example with a `helm install ... --set-string spire.dbPassword=$(openssl rand -hex 24)` approach) so no fixed credentials land in manifests.

## Cleanup

```bash
kubectl delete -k k8s/demo/base/spire
```
