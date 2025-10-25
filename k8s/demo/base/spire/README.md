# ServiceRadar Demo SPIRE Setup

Manifests in this directory bootstrap SPIFFE/SPIRE inside the demo Kubernetes namespace. They are **not** part of the default demo kustomization; apply them separately while we iterate on the onboarding workflow.

## Quick Start

1. **Provision the database secret (CNPG namespace)**  
   Generate a password locally and create the `spire-db-credentials` secret in the `cnpg-system` namespace—never commit real secrets to git. Example:

   ```bash
   openssl rand -hex 24 > /tmp/spire-db-pass
   kubectl create secret generic spire-db-credentials \
     --from-literal=username=spire \
     --from-file=password=/tmp/spire-db-pass \
     --namespace cnpg-system
   rm /tmp/spire-db-pass
   ```

   Alternatively, copy `k8s/cnpg/spire-db-credentials.yaml` into a private repository, populate the password there, and apply it from that location.

2. **Apply the CNPG cluster resources**

   ```bash
   kubectl apply -f k8s/cnpg/new-pg-cluster.yaml
   ```

3. **Deploy SPIRE server + agent**

   ```bash
   kubectl apply -k k8s/demo/base/spire
   ```

   The included `pg-secret-sync` job mirrors the `cnpg-system/spire-db-credentials` secret into the SPIRE namespace as `spire-postgres`, so no additional secret manifests are required in this tree.

4. **(Optional) Watch for readiness**

   ```bash
   kubectl get pods -n spire -w
   ```

5. **Register node entries if needed** (the post-start hook covers the default case—see below).

## Registering Agents and Workloads

The SPIRE server StatefulSet automatically creates registration entries for the SPIRE agent DaemonSet, `serviceradar-core`, and `serviceradar-poller`. If you need to register additional workloads, use the following commands as a template.

Create the node registration entry so the SPIRE agent running as a DaemonSet can establish trust with the server:

```shell
kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -node \
    -spiffeID spiffe://carverauto.dev/ns/spire/sa/spire-agent \
    -selector k8s_sat:cluster:carverauto-cluster \
    -selector k8s_sat:agent_ns:spire \
    -selector k8s_sat:agent_sa:spire-agent
```

Register additional workloads (replace the namespace/service account as needed):

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
- The demo server `Service` is a `NodePort` exposing gRPC on `8081`. Ensure firewall rules (or layer-7 routing) allow edge or remote agents to reach that port, plus the HTTP health port `8080` if you monitor readiness externally.
- For Helm or other packaging flows, mirror the secret-generation step above—for example `helm install ... --set-string spire.dbPassword=$(openssl rand -hex 24)`—so credentials are injected at install time instead of checked into git.

## Cleanup

```bash
kubectl delete -k k8s/demo/base/spire
```
