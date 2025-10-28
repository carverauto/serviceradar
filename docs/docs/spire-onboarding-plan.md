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

## 9. Nested poller SPIRE bootstrap (serviceradar-53)

### Requirements recap

- `serviceradar-poller` now embeds a downstream SPIRE server/agent pair. The
  upstream agent (the sidecar that connects back to the cluster-level SPIRE
  server) must authenticate with a deterministic parent ID so the downstream
  registration entry is released. The previous `k8s_psat` attestation failed
  because SPIRE minted per-node SVIDs (`…/k8s_psat/<cluster>/<nodeUID>`), which
  never matched the static `downstream` entry that was parented to the server
  itself.
- We need a flow that works for:
  1. **Kubernetes demo/Helm** – fully automated, idempotent, no manual `kubectl
     exec` after deployment.
  2. **Docker Compose / bare metal** – poller can run outside Kubernetes and
     still obtain downstream credentials with minimal operator steps.
  3. **Edge installs** – admins should be able to issue new tokens safely if a
     poller is reprovisioned.

### Proposed approach

1. **Use join-token node attestation for the upstream poller agent.**
   - SPIRE server: enable the built-in `join_token` node attestor alongside
     `k8s_psat` (`doc/plugin_server_nodeattestor_jointoken.md`). Tokens are
     minted via `CreateJoinToken` (server Agent API) and result in deterministic
     agent SVIDs (`spiffe://<trust_domain>/spire/agent/join_token/<token>`).
   - Poller upstream agent: switch `upstream-agent.conf` to the `join_token`
     plugin and load the token from `/run/spire/nested/credentials/join_token`.
     The agent CLI supports `join_token` via either the `-joinToken` flag or the
     `join_token` block in `agent.conf`.
   - Downstream registration entry: parent the `downstream` entry to the join
     token SVID (`spiffe://carverauto.dev/spire/agent/join_token/<token>`),
     ensuring SPIRE authorizes the agent once it redeems the token.

2. **Automate join-token issuance.**
   - Add a new `serviceradar-cli spire join-token` command that calls the SPIRE
     Agent API (`CreateJoinToken`) over the admin socket. The command should:
       * accept `--spiffe-id`, `--ttl`, and `--socket-path`/`--address` flags,
       * write the token material to stdout or a file,
       * optionally apply the downstream entry (via `spire-server entry create`)
         when given `--register-downstream`.
   - Package the CLI inside `serviceradar-tools` so Kubernetes Jobs and operators
     can invoke it without bundling raw SPIRE binaries.
   - Provide a thin HTTP shim in core (Admin API) so remote/edge installs can
     request tokens without direct server access. The API should require an
     authenticated admin session and log every issuance for auditability.

3. **Kubernetes automation (demo + Helm).**
   - Introduce a `Job` (or `initContainer`) that runs `serviceradar-cli spire
     join-token --spiffe-id spiffe://carverauto.dev/ns/demo/poller-nested-spire`
     and writes the token into a Secret (`poller-nested-spire-token`). The job
     checks whether the Secret already exists; if so, it exits successfully to
     stay idempotent. When the job recreates the Secret (e.g., after a manual
     deletion), it should also reconcile the downstream entry.
   - Update the poller Deployment to mount the Secret into the upstream agent
     sidecar and to reference `join_token` in the config map.
   - Extend Helm values with `nestedSpire.joinToken.enabled` plus knobs for TTL,
     secret name, and optional regeneration policy. Document how to rotate the
     token by deleting the Secret and re-running the job.

4. **Docker Compose / bare metal.**
   - Reuse `serviceradar-cli spire join-token` to mint a token against the main
     SPIRE server (reachable via `SPIRE_SERVER_ADDR`). The existing
     `bootstrap-nested-spire.sh` script should:
       * request a token and store it in `${NESTED_SPIRE_DIR}/join_token`,
       * call the CLI to create/update the downstream entry with the matching
         parent,
       * start the upstream agent once the token is written.
   - For high-security environments, document an alternative x509pop flow (pre-
     provisioned certificate) and show how to swap the agent config to
     `NodeAttestor "x509pop"` without affecting the platform defaults.

5. **Rotation and observability.**
   - Tokens are single use; once the agent boots it should delete the file (or
     move it to a rotated directory) so accidental reuse fails fast.
   - Add Grafana/Prometheus alerts on the SPIRE server for repeated join-token
     issuance failures and unauthorized downstream attempts.
   - Ensure the bead (`serviceradar-53`) tracks the implementation milestones
     and references these docs.

### Outstanding questions

- How do we authenticate callers of the admin join-token API (mutual TLS vs.
  existing ServiceRadar admin auth)?
- Should we enforce per-cluster rate limits or quotas on join-token issuance to
  mitigate abuse?
- Do we require operators to manually approve poller tokens for federated/
  multi-tenant environments, or can the API auto-approve when scoped to a
  tenant?

### Admin API + RBAC flow

To support remote onboarding from the ServiceRadar UI or CLI:

1. **HTTP endpoint:** add `POST /api/admin/spire/join-tokens` guarded by the
   existing RBAC middleware (`admin` role by default). Request body:
   ```json
   {
     "client_spiffe_id": "spiffe://carverauto.dev/ns/demo/poller-nested-spire",
     "ttl_seconds": 900,
     "register_downstream": true,
     "downstream": {
       "spiffe_id": "spiffe://carverauto.dev/ns/demo/poller-nested-spire",
       "selectors": [
         "unix:uid:0",
         "unix:gid:0",
         "unix:user:root",
         "unix:path:/opt/spire/bin/spire-server"
       ],
       "x509_svid_ttl": "4h",
       "jwt_svid_ttl": "30m"
     }
   }
   ```
   Response body:
   ```json
   {
     "token": "abc123",
     "expires_at": "2025-10-28T00:14:03Z",
     "spiffe_id": "spiffe://carverauto.dev/spire/agent/join_token/abc123",
     "downstream_entry_id": "f8b7..."
   }
   ```
   - `register_downstream` drives whether the API immediately creates the
     downstream entry with `parent_id` set to the join-token SVID, `downstream:
     true`, and `admin: true` when requested.
   - Validation: TTL within configurable bounds (default 10 minutes, max 24h),
     `client_spiffe_id` must match trust domain, and only whitelisted templates
     can be issued (e.g., `/ns/<ns>/poller-nested-spire`).

2. **SPIRE access:** Core obtains a Workload API SVID and uses it to connect to
   the SPIRE server `Agent` and `Entry` gRPC services. A dedicated
   `ClusterSPIFFEID` must mark the core identity as `admin: true` so these RPCs
   are authorized.

3. **Auditing:** Every issuance is recorded (token ID, parent, downstream entry,
   user identity) in the core database for traceability. Optionally emit an
   audit log event via the existing alerts pipeline.

4. **CLI integration:** `serviceradar spire-join-token` hits the new endpoint
   using JWT/API-key auth. This avoids distributing SPIRE admin credentials to
   operators while still enabling edge onboarding. Use `-output` to persist the
   JSON response and extract the token for automation.

5. **Rate limits:** add simple per-user limit (e.g., 10 tokens per minute) and
   optional global throttle to prevent abuse. Future work can layer on more
   comprehensive policy controls.

Update this section as we implement the CLI, Kubernetes automation, and
packaging changes for issue `serviceradar-53`.

Please update this plan as we refine the SPIRE rollout strategy.
