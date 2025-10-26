# SPIFFE/SPIRE Onboarding Plan

This document captures the working plan for integrating SPIFFE/SPIRE-based
identity provisioning across ServiceRadar environments. It aligns with
bead `serviceradar-52`, GitHub issues #1891/#1892, and the ongoing effort to
replace ad-hoc TLS bootstrap with SPIRE-issued SVIDs.

## 1. Current State

- **Demo cluster:** SPIRE server/agents run inside the `demo` namespace with a
  LoadBalancer service (`spire-server:8081`) that edge agents can reach on
  `192.168.6.80`. The server uses the `k8s_sat` node attestor with Kubernetes
  TokenReview validation enabled.
- **Data store:** SPIRE persists state in a CloudNativePG cluster defined by
  `k8s/demo/base/spire/spire-postgres-cluster.yaml`. The backing credentials are
  provided via the `spire-db-credentials` secret (replace the placeholder
  password before applying).
- **Registration:** The SPIRE Controller Manager now runs as a sidecar inside
  the server StatefulSet and reconciles the `ClusterSPIFFEID` CRDs
  (`spire-clusterspiffeid-*.yaml`) so demo workloads (core, poller, datasvc,
  serviceradar-agent) receive SVIDs automatically. Legacy scripts remain under
  `k8s/demo/base/spire/` for reference but are no longer part of the bootstrap
  path.
- **Workloads:** Core/poller still read mTLS material from static ConfigMaps.
  They do **not** request SVIDs from SPIRE, so switching them requires both an
  identity registration flow and application integration.

## 2. Goals

1. **Idempotent bootstrap** – Installing SPIRE (demo, Helm, bare metal) should
   generate database credentials, stand up server/agents, and register a
   baseline set of identities without manual `kubectl exec` steps.
2. **Zero-touch workload onboarding** – ServiceRadar services (core, poller,
   sync, agent tiers) should be able to request and rotate SPIFFE identities via
   environment variables only (no baked-in certificates).
3. **Edge reachability** – Remote agents/pollers must reach the SPIRE server
   securely. Document ingress/port exposure for Kubernetes, Docker Compose, and
   bare-metal installs.
4. **Packaging parity** – Deliver the same automation through Helm and the demo
   kustomization. Docker/bare-metal builds fall back to SQLite for SPIRE while
   Kubernetes uses Postgres.

## 3. Registration Automation Options

| Option | Pros | Cons | Notes |
|--------|------|------|-------|
| **A. Kubernetes Job + CLI (deprecated)** | Simple to reason about, runs once per deploy, leverages existing manifests | Required `kubectl` inside a bespoke image and cluster-admin RBAC; replaced by controller-manager | Kept in history only. |
| **B. SPIRE Kubernetes Workload Registrar (controller-manager)** | Fully declarative via CRDs, production-proven, auto-syncs entries | Additional controller deployment, introduces CRDs we must package/test, learning curve for operators | **Adopted** – ships as a sidecar with the server. |
| **C. External automation via `serviceradar-cli`** | Reuses our tooling, covers bare metal installs uniformly | Requires operators to remember an extra step; still need credentials and kube context | Useful fallback for air-gapped installs. |

**Recommendation:** Continue investing in Option B (controller manager) for all
Kubernetes flows. Option A has been removed; Option C remains a potential
escape hatch for non-Kubernetes installs.

### 3.1 Controller Manager Deployment (Option B)

- Packaging: the SPIRE Controller Manager binary ships as a sidecar container
  (`ghcr.io/spiffe/spire-controller-manager:0.6.3`) inside the server
  StatefulSet. We mount a shared emptyDir at `/tmp/spire-server/private` for
  the admin socket and expose it to the controller under `/spire-server`.
- Configuration: `spire-controller-manager-config` (ConfigMap) defines the
  trust domain, cluster name, leader election settings, and ignores default
  Kubernetes namespaces. The controller talks to the server via the unix socket
  (`/spire-server/api.sock`) so nothing is exposed over the network.
- RBAC: `spire-controller-manager` (ClusterRole + ClusterRoleBinding) grants
  access to pods/nodes and the SPIRE CRDs. A namespace-scoped Role/RoleBinding
  handles leader-election ConfigMaps/Leases.
- Declarative identities: `spire-clusterspiffeid-*.yaml` resources describe the
  SVIDs we need. The controller reconciles these CRDs and keeps SPIRE entries in
  sync, pruning stale registrations automatically.
- Helm/demo parity: both the Kustomize demo and the Helm chart ship the same
  CRDs, RBAC, ConfigMap, and StatefulSet sidecar logic so upgrades behave the
  same across packaging flows.

## 4. External/Edge Connectivity

- **Kubernetes (demo):** `k8s/demo/base/spire/server-service.yaml` already uses
  `type: LoadBalancer`. Document the external IP (`kubectl get svc
  -n demo spire-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`) and
  ensure firewall rules expose TCP/8081 to managed endpoints. If metallb is in
  play, allocate a static IP and record it in the runbook.
- **Helm installs:** Provide a values block to switch between `ClusterIP`,
  `NodePort`, and `LoadBalancer`. Default to `ClusterIP` when running fully
  inside-cluster; document how to enable ingress or TLS termination as needed.
- **Docker Compose / bare metal:** Expose port 8081 on the host and configure
  agents with `SPIRE_SERVER_ADDR=<hostname>:8081`. For bare metal, ensure the
  server certificate’s SAN covers that hostname or IP (leveraging the same
  cert-manager workflow or packaged CA).

## 5. Secrets & Password Management

- `k8s/demo/base/spire/spire-db-credentials.yaml` includes a placeholder. Prior
  to committing an environment, generate a 32+ character password via
  `openssl rand -hex 24` and apply it with `kubectl apply -f ...`. Do **not**
  commit generated passwords to git.
- Helm chart should accept `postgres.passwordExistingSecret` to avoid rendering
  credentials into the manifest.
- Docker/bare-metal: default to SQLite datastore; offer environment overrides
  for pointing to Postgres if desired.

## 6. Roadmap

1. **Controller manager rollout** – ✅ Landed. SPIRE server now ships with the
   controller-manager sidecar plus CRDs/RBAC in both the demo kustomization and
   the Helm chart; declarative `ClusterSPIFFEID` resources replace the old
   bootstrap job.
2. **SPIFFE-enabled workloads** – Core/poller/datasvc/serviceradar-agent use
   SPIRE-issued SVIDs. Finish migrating mapper, sync, and checker deployments
   and prune legacy mTLS cert mounts once complete.
3. **Helm parity** – ✅ Helm renders the same controller-manager resources and
   ClusterSPIFFEID definitions; continue validating chart upgrades and values
   overrides.
4. **Edge packaging** – Add `serviceradar-cli` support (or another bootstrap
   helper) for non-Kubernetes installs that cannot run the controller manager.
5. **SPIFFE everywhere** – Track follow-up work to remove residual TLS material
   from KV/configs and rely exclusively on SPIFFE identities across services.

## 7. Open Questions

- Should SPIRE run in its own namespace in production, or stay co-located with
  ServiceRadar components? (affects RBAC and secret scoping)
- How do we expose SPIRE to edge agents in multitenant clusters without a
  public LoadBalancer (e.g., via an Authenticated Ingress)?
- Can we rely on TokenReview in air-gapped/offline clusters, or do we need
  alternative attestors (e.g., JWT-SVID bootstrap)?

## 8. Next Actions (tracked in serviceradar-52)

- [x] Ship the controller-manager sidecar, CRDs, and RBAC in demo/Helm so
      declarative `ClusterSPIFFEID` objects register core/poller/datasvc/
      serviceradar-agent automatically.
- [ ] Finish SPIFFE migrations for mapper/sync/checker workloads and delete
      their legacy mTLS cert mounts once tests pass.
- [ ] Provide a `serviceradar-cli` (or similar) bootstrap path for
      non-Kubernetes installs that cannot run the controller manager.
- [ ] Backfill integration coverage for KV overlay stripping and SPIFFE
      handshakes to catch regressions automatically.

Please update this plan as we refine the SPIRE rollout strategy.
