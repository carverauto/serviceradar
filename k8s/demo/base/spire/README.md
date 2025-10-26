# ServiceRadar Demo SPIRE Setup

Manifests in this directory bootstrap SPIFFE/SPIRE inside the `demo` Kubernetes namespace alongside the rest of the ServiceRadar stack. They are **not** part of the default demo kustomization; apply them separately while we iterate on the onboarding workflow.

## Quick Start

1. **Provision the database secret (demo namespace)**  
   Generate a password locally and update `spire-db-credentials.yaml` (or replace it with a file you keep out of git) so the `demo` namespace receives the credentials SPIRE and its Postgres cluster will share:

   ```bash
   openssl rand -hex 24 > /tmp/spire-db-pass
   cat <<'EOF' > k8s/demo/base/spire/spire-db-credentials.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: spire-db-credentials
     namespace: demo
   type: Opaque
   stringData:
     username: spire
     password: "$(cat /tmp/spire-db-pass)"
   EOF
   rm /tmp/spire-db-pass
   ```

   Alternatively, generate the secret straight into the cluster with `kubectl create secret generic spire-db-credentials ... --namespace demo` **before** running the kustomization.

2. **Apply the in-namespace Postgres cluster + SPIRE stack**

   ```bash
   kubectl apply -k k8s/demo/base/spire
   ```

   This creates a dedicated three-instance `spire-pg` CNPG cluster inside the demo namespace alongside the SPIRE server/agent. If you previously relied on the global `cluster-pg` instance in `cnpg-system`, the SPIRE server config now points to the new in-namespace endpoint (`spire-pg-rw.demo.svc.cluster.local`).

   > **Migration tip:** If you deployed an earlier revision of these manifests (or the standalone `cnpg-system` cluster), delete those legacy resources once the new ones are healthy so only the demo-scoped installation remains.

3. **(Optional) Watch for readiness**

   ```bash
   kubectl get pods -n demo -l app=spire-server -w
   ```

4. **Automatic bootstrap**

   Applying the kustomization now creates the `spire-bootstrap` Job, which waits
   for the server pod to become Ready and seeds baseline registration entries
   (agent node alias, `serviceradar-core`, `serviceradar-poller`). Inspect the
   Job status with:

   ```bash
   kubectl get jobs -n demo spire-bootstrap
   kubectl logs -n demo job/spire-bootstrap
   ```

   To rerun the bootstrap (for example after editing selectors), delete the job
   and reapply it:

   ```bash
   kubectl delete job -n demo spire-bootstrap --ignore-not-found
   kubectl apply -f k8s/demo/base/spire/bootstrap-job.yaml
   ```

## Registering Agents and Workloads

The bootstrap Job provisions the defaults. If you need to re-run it or add
additional identities, use the following commands as templates.

Create the node registration entry so the SPIRE agent running as a DaemonSet can establish trust with the server:

```shell
SPIRE_NAMESPACE=${SPIRE_NAMESPACE:-demo}
kubectl exec -n "${SPIRE_NAMESPACE}" spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -node \
  -spiffeID "spiffe://carverauto.dev/ns/${SPIRE_NAMESPACE}/sa/spire-agent" \
  -selector k8s_sat:cluster:carverauto-cluster \
  -selector "k8s_sat:agent_ns:${SPIRE_NAMESPACE}" \
  -selector k8s_sat:agent_sa:spire-agent
```

Register additional workloads (replace the namespace/service account as needed):

```shell
SPIRE_NAMESPACE=${SPIRE_NAMESPACE:-demo}
kubectl exec -n "${SPIRE_NAMESPACE}" spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://carverauto.dev/ns/default/sa/default \
  -parentID "spiffe://carverauto.dev/ns/${SPIRE_NAMESPACE}/sa/spire-agent" \
  -selector k8s:ns:default \
  -selector k8s:sa:default
```

## Additional Assets

- `client-deployment.yaml`, `cert-certificate.yaml`, and related issuer manifests are provided for experimentation and are intentionally excluded from `kustomization.yaml`. Apply or customize them manually if you need TLS automation beyond the demo defaults.
- `test.sh` contains a basic sanity check that fetches an SVID from within the cluster.
- The demo server `Service` is a `LoadBalancer` exposing gRPC on `8081` and the optional HTTP health endpoint on `8080`. If your Kubernetes environment lacks an external load-balancer implementation, patch the service to the exposure model you prefer (NodePort, Ingress, etc.) before onboarding edge agents. To confirm the external IP: `kubectl get svc spire-server -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`.
- For Helm or other packaging flows, mirror the secret-generation step above—for example `helm install ... --set-string spire.dbPassword=$(openssl rand -hex 24)`—so credentials are injected at install time instead of checked into git.
- Longer-term automation, edge connectivity options, and parity goals are tracked in `docs/docs/spire-onboarding-plan.md`.

## Cleanup

```bash
kubectl delete -k k8s/demo/base/spire
```
