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

4. **Automatic registration**

   The SPIRE Controller Manager now runs as a sidecar in the server StatefulSet.
   Once the server is Ready it reconciles the `ClusterSPIFFEID` custom resources
   in this directory and creates the corresponding registration entries for the
   demo workloads (core, poller, datasvc, serviceradar-agent). Observe the
   controller’s view with:

   ```bash
   kubectl get clusterspiffeids.spire.spiffe.io -n demo
   kubectl describe clusterspiffeid.serviceradar-core -n demo
   ```

   Updates to the manifests are picked up automatically; reapplying the
   kustomization is idempotent.

## Registering Agents and Workloads

The controller manager sources workload identities from `ClusterSPIFFEID`
resources. To onboard a new deployment, author a manifest patterned after the
existing `spire-clusterspiffeid-*.yaml` files and apply it to the cluster. For
example, to issue `spiffe://carverauto.dev/ns/demo/sa/custom-checker` to pods
labelled `app=custom-checker`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: custom-checker
spec:
  spiffeIDTemplate: spiffe://carverauto.dev/ns/demo/sa/custom-checker
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: demo
  podSelector:
    matchLabels:
      app: custom-checker
EOF
```

The Kubernetes PSAT node attestor continues to handle agent node registration,
so manual `spire-server entry create -node` invocations are no longer required.
You can still use the SPIRE CLI for ad-hoc entries, but declarative CRDs keep
the demo environment reproducible.

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
