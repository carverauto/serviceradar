# SPIFFE / SPIRE Identity Platform

This guide explains how ServiceRadar provisions and consumes SPIFFE identities
via the SPIRE runtime we ship for Kubernetes environments. It documents the
controller-manager sidecar, our set of custom resources, and day-two
automation so operators can reason about certificate issuance, workload
registration, and the fallbacks available for non-Kubernetes installs.

## High-Level Overview

- **SPIRE Server StatefulSet** – Runs in-cluster inside the `demo` namespace
  (and via Helm for customer namespaces). The pod now hosts two containers:
  the upstream `spire-server` binary and the `spire-controller-manager`
  sidecar that owns workload registration.
- **Postgres datastore** – SPIRE persists state in the `spire-pg` CNPG
  cluster, provisioned alongside the server manifests. Credentials live in the
  `spire-db-credentials` secret and should be rotated per environment.
- **SPIRE Agent DaemonSet** – Deployed on every node to surface the Workload
  API socket (`/run/spire/sockets/agent.sock`). ServiceRadar workloads mount
  this socket to request SVIDs at runtime.
- **Controller-managed registration** – Instead of shelling into the server to
  seed entries, we declare identities through Kubernetes CRDs
  (`ClusterSPIFFEID`, `ClusterStaticEntry`, `ClusterFederatedTrustDomain`). The
  controller reconciles these objects and keeps SPIRE in sync whenever pods or
  selectors change.

## Controller Manager Sidecar

We ship the controller as a sidecar in the same StatefulSet as the server to
keep the admin socket scoped to the pod. Key configuration details:

- ConfigMap `spire-controller-manager-config` renders a
  `ControllerManagerConfig` object with the trust domain, cluster name, and
  ignore list. The controller dials the server using the shared socket under
  `/spire-server/api.sock`.
- Validating webhooks are disabled by default (`ENABLE_WEBHOOKS=false`)
  because the demo environment does not yet supply the webhook service and TLS
  assets. If you enable webhooks in a hardened cluster, set
  `enableWebhooks=true` and ensure cert-manager injects the required
  certificates.
- RBAC binds the server’s service account to the controller role so the
  sidecar can list pods, nodes, and manipulate the SPIRE CRDs.

## Declarative Workload Registration

### ClusterSPIFFEID

Workload identities are declared via `ClusterSPIFFEID` resources. Each
resource defines:

- `spiffeIDTemplate` – The SVID URI issued to matching workloads (for
  example `spiffe://carverauto.dev/ns/demo/sa/serviceradar-core`).
- `namespaceSelector` and `podSelector` – Label selectors that determine which
  pods receive the SVID.
- Optional extras such as `federatesWith`, `workloadSelectorTemplates`, or
  fallback semantics.

Example (`spire-clusterspiffeid-core.yaml`):

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: serviceradar-core
spec:
  spiffeIDTemplate: spiffe://carverauto.dev/ns/demo/sa/serviceradar-core
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: demo
  podSelector:
    matchLabels:
      app: serviceradar-core
```

Once applied, the controller notices matching pods and programs the SPIRE
server with the appropriate parent/child entries. No manual `spire-server
entry create` calls are required.

### ClusterStaticEntry & Federation

We also ship CRDs for static entries and trust-domain federation. These are not
yet in use, but the manifests are available for multi-cluster deployments.
Operators can add `ClusterStaticEntry` objects for non-Kubernetes workloads or
use `ClusterFederatedTrustDomain` to extend identities across clusters.

## Consumption by ServiceRadar Components

ServiceRadar services opt into SPIFFE by setting `security.mode=spiffe` in
their base configuration (kept in ConfigMaps/Helm chart values). Important
runtime expectations:

1. **Socket mount** – Pods mount `/run/spire/sockets` from the host. Our Helm
   chart and demo manifests add the hostPath volume automatically.
2. **KV overlay protection** – `pkg/config` strips `.security` blocks from KV
   overlays so the SPIFFE mode cannot be overwritten by remote configuration.
3. **RBAC checks** – Datasvc and other control-plane services inspect the
   SPIFFE URI from client certificates (SAN URI) instead of legacy CN values.

As of this change, `serviceradar-core`, `serviceradar-poller`, `serviceradar-
datasvc`, and the `serviceradar-agent` chart/manifests ship in SPIFFE mode.
Mapper/sync/checkers are queued for migration.

## Operational Notes

- Applying `k8s/demo/base/spire` (or `helm upgrade`) is idempotent. The
  StatefulSet restarts to pick up controller config changes and immediately
  replays the declarative entries.
- Inspect current identities with `kubectl get clusterspiffeids.spire.spiffe.io`
  and review reconciliation logs via `kubectl logs -n <ns> <spire-server pod>
  -c spire-controller-manager`.
- Agents still use the standard DaemonSet; ensure the host path exposes the
  Workload API socket to workloads.
- For environments that cannot host the controller (e.g. air-gapped bare
  metal), we plan to expose a `serviceradar-cli` bootstrap path that programs
  entries directly through the SPIRE API. Until then the controller remains the
  authoritative path on Kubernetes.

## Next Steps

- Migrate the remaining workloads (mapper, sync, checkers) to SPIFFE and drop
  their ConfigMap-provided TLS certificates.
- Mirror the same controller-manager deployment in production Helm values with
  the webhook configuration enabled once we supply the validating webhook
  service.
- Provide a CLI-based bootstrap helper for non-Kubernetes installs.

Refer back to this document whenever updating SPIRE manifests, CRDs, or
ServiceRadar configuration so we keep the declarative system aligned across
packaging targets.
