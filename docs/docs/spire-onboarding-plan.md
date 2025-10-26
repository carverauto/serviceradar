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
- **Registration:** The earlier `postStart` hook in the StatefulSet was removed
  (distroless image lacks `/bin/sh`). Manual scripts under
  `k8s/demo/base/spire/create-node-registration-entry.sh` seed node entries, but
  there is no automated flow for ServiceRadar workloads yet.
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
| **A. Kubernetes Job + CLI** | Simple to reason about, runs once per deploy, leverages existing manifests | Needs a shell-capable image that bundles `spire-server` CLI; must handle idempotency for repeated runs | Proposed near-term stopgap. |
| **B. SPIRE Kubernetes Workload Registrar (controller-manager)** | Fully declarative via CRDs, production-proven, auto-syncs entries | Additional controller deployment, introduces CRDs we must package/test, learning curve for operators | Preferred medium-term once we are comfortable shipping CRDs. |
| **C. External automation via `serviceradar-cli`** | Reuses our tooling, covers bare metal installs uniformly | Requires operators to remember an extra step; still need credentials and kube context | Useful fallback for air-gapped installs. |

**Recommendation:** Implement Option A immediately for demo/Helm flows, while
spiking Option B in parallel. We can keep the Job definition in Kustomize and
mirror it into the Helm chart once validated.

### 3.1 Job Design (Option A)

- Image: extend `serviceradar-tools` to include the SPIRE CLI binaries and
  `kubectl`. This keeps the job self-contained and matches the tooling already
  shipped for operators.
- Execution:
  1. Wait for the SPIRE server pod to become Ready.
  2. Discover the server pod name and run `spire-server entry show/create`
     _inside the pod_ via `kubectl exec` so we can use the unix admin socket
     without exposing it over the network.
  3. Ensure workload entries exist for:
     - `spiffe://carverauto.dev/ns/demo/sa/serviceradar-core`
     - `spiffe://carverauto.dev/ns/demo/sa/serviceradar-poller`
     Additional services can be appended later.
  4. Exit successfully without error if entries already exist (script remains
     idempotent thanks to JSON inspection).
- Trigger: Run as a `Job` with `backoffLimit: 4`, labeled so that we can hook it
  into Helm post-install and demo `kustomize build`.
- Future: Replace with the workload registrar once we adopt CRDs.

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

1. **Bootstrap Job (demo)** – ✅ Landed. `spire-bootstrap` seeds node/core/poller
   entries automatically after apply.
2. **Core/Poller integration** – Update service deployments to mount the agent
   socket, request SVIDs, and switch gRPC security (see `pkg/grpc/security.go`).
   Provide feature flags to fall back to static certs while we iterate.
3. **Helm parity** – Mirror the SPIRE manifests, job, and service exposure into
   the ServiceRadar Helm chart (new `spire.enabled` values block).
4. **Workload registrar** – Evaluate `spire-controller-manager` for declarative
   registration; migrate once comfortable.
5. **Edge packaging** – Add `serviceradar-cli spire bootstrap` command that can
   run against Kubernetes, Docker, or bare metal to generate the same entries
   without cluster-admin privileges (reuses Option A logic).
6. **SPIFFE everywhere** – Gradually migrate remaining services (sync, web,
   agents) to trust SPIRE-issued identities, dropping legacy cert ConfigMaps.

## 7. Open Questions

- Should SPIRE run in its own namespace in production, or stay co-located with
  ServiceRadar components? (affects RBAC and secret scoping)
- How do we expose SPIRE to edge agents in multitenant clusters without a
  public LoadBalancer (e.g., via an Authenticated Ingress)?
- Can we rely on TokenReview in air-gapped/offline clusters, or do we need
  alternative attestors (e.g., JWT-SVID bootstrap)?

## 8. Next Actions (tracked in serviceradar-52)

- [x] Build `serviceradar-tools` with the SPIRE CLI and add the bootstrap Job.
- [ ] Create helm values and documentation for SPIRE external exposure.
- [x] Document password generation flow in the demo README.
- [ ] Prototype workload socket mount for `serviceradar-core` and validate mTLS
      handshake using SPIFFE identities.

Please update this plan as we refine the SPIRE rollout strategy.
