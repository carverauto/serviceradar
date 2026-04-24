## Context

ServiceRadar already deploys PostgreSQL through CloudNativePG and already maintains a custom CNPG image at `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd`. The demo manifests and Helm chart already encode the cluster bootstrap, secret reuse, and extension initialization patterns that ServiceRadar expects for CNPG-managed workloads.

The requested Honcho work is not just a database addition. Honcho self-hosting requires a small application stack around the memory provider, including:
- a persistent PostgreSQL database
- runtime services for the Honcho API and dashboard
- background/worker processing
- Redis for queue/cache/background coordination
- Kubernetes-managed secrets and public/internal URL wiring

This change should fit that stack into the existing ServiceRadar deployment conventions instead of introducing a one-off database or a standalone unmanaged compose environment.

Per user direction, the Honcho stack should be isolated into a dedicated Kubernetes namespace named `honcho`. The namespace should contain the Honcho application services, the HA Redis deployment, and a dedicated Honcho CNPG cluster managed by the existing CNPG operator rather than by reusing any existing ServiceRadar database cluster.

Also per user direction, the Kubernetes deployment artifacts for Honcho should live in `~/src/gitops`, not in the ServiceRadar application repo. The ServiceRadar repo remains the right place for the OpenSpec change, architecture/design notes, and any app-specific implementation work, but GitOps ownership for namespace/app manifests should live in the GitOps repo.

## Goals

- Deploy Honcho in Kubernetes using a dedicated CNPG-backed PostgreSQL cluster for durable memory state.
- Isolate the Honcho stack into a dedicated `honcho` namespace.
- Reuse the existing ServiceRadar CNPG custom image and secret/bootstrap conventions while letting the CNPG operator manage a new Honcho cluster.
- Model Honcho's required supporting services explicitly, including an HA Redis deployment and worker/background processing.
- Provide a repeatable configuration path for database, Redis, URL, auth/session secrets, and controlled service exposure for Hermes/operator access, with Kubernetes manifests living in the GitOps repo.
- Deliver GitOps-managed secrets through SealedSecrets rather than committing raw Secret manifests.
- Make startup dependencies and validation steps explicit so operators can deploy and verify the stack in demo.

## Non-Goals

- Replacing ServiceRadar's primary CNPG cluster or changing existing ServiceRadar application database ownership.
- Reusing an existing ServiceRadar database cluster for Honcho's first deployment.
- Designing a multi-tenant Honcho control plane in this change.
- Committing to production internet exposure details before the base internal deployment works.
- Defining Honcho-specific feature behavior beyond what is needed to self-host the memory provider stack.

## Design

### 1. Namespace and database model: dedicated `honcho` namespace and dedicated Honcho CNPG cluster
Honcho SHALL run in a dedicated Kubernetes namespace named `honcho` and SHALL use a dedicated CNPG-managed PostgreSQL cluster rather than sharing ad hoc credentials with the primary ServiceRadar application database or reusing an existing CNPG cluster.

The Honcho CNPG cluster SHOULD:
- live in the `honcho` namespace alongside the rest of the Honcho stack
- use `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd` or the corresponding pinned digest form already used in demo manifests
- define a dedicated database, owner role, and Kubernetes secret for Honcho
- be managed by the existing CNPG operator as a new cluster resource
- reuse the existing ServiceRadar CNPG patterns for `Cluster`, bootstrap `initdb`, secret persistence, and internal-only service exposure by default

### 2. Runtime model: explicit Honcho services
The deployment SHALL treat Honcho as an application stack made of separate runtime roles instead of a single opaque container.

At minimum, the deployment SHOULD model:
- Honcho API/backend
- Honcho dashboard/UI
- Honcho worker/background processor if packaged separately
- an HA Redis deployment as a required supporting service for queues/cache/background coordination

### 3. Configuration model: secret-backed env-driven deployment
Honcho self-hosting SHALL be configured through Kubernetes secrets/config rather than handwritten in-container edits.

The deployment SHOULD surface configuration for:
- PostgreSQL connection string or equivalent database connection fields
- Redis connection string
- public/base URL settings used by the API and dashboard
- auth/session/encryption secrets required by Honcho
- runtime environment/mode values required for self-hosting

Where the Honcho docs define exact environment variable names, implementation SHOULD use those exact names instead of inventing ServiceRadar-specific aliases.

### 4. Startup sequencing and readiness
The deployment SHALL make dependency ordering explicit.

Honcho application pods SHOULD NOT be considered Ready until:
- the `honcho` namespace prerequisites have been created
- the dedicated Honcho CNPG cluster is reachable
- the required schema initialization/migrations have completed
- the HA Redis deployment is reachable for components that require background processing

The implementation SHOULD choose a startup pattern that makes failure states obvious, such as init jobs/init containers or explicit migration jobs.

### 5. Exposure model: internal-first with controlled private-network access for Hermes and operators
The initial deployment SHOULD be cluster-internal by default inside the `honcho` namespace and SHOULD be reconciled through GitOps/Argo CD rather than imperative kubectl/helm deployment as the steady-state workflow.

The design SHOULD support a controlled access path for the Honcho API and dashboard so Hermes Agent and operators can reach Honcho from the internal network without exposing it on a broadly public 80/443 endpoint.

Preferred exposure order:
- durable access: private/internal Envoy Gateway or similar Kubernetes-managed entrypoint backed by a private/internal LoadBalancer IP
- temporary testing only: port-forwarding
- public ingress: only if explicitly approved and justified

For the current Honcho rollout, the preferred DNS shape SHOULD be a single hostname (`honcho.carverauto.dev`) with path-based routing, where the dashboard/UI is served at `/` and the API is served under `/api`, unless upstream Honcho runtime requirements force a different routing shape.

Any external or semi-external exposure SHOULD:
- be limited to the Honcho API and/or dashboard services
- keep CNPG and Redis internal-only
- avoid allocating a broad public 80/443 endpoint by default
- be documented as an explicit opt-in deployment step rather than the default bootstrap path

## Risks

- Honcho may require a specific migration/init flow that needs to be encoded as a job rather than a simple Deployment startup command.
- The exact Honcho self-hosting environment variable names still need to be copied from upstream docs during implementation and should not be guessed.
- The HA Redis topology needs to be chosen carefully so it is operationally simple enough for demo while still matching the required failure characteristics.
- Honcho compatibility with PostgreSQL 18.3 and the ServiceRadar CNPG custom image needs to be validated with actual startup and migration runs.

## Open Questions

- Which HA Redis deployment pattern should ServiceRadar prefer for demo and future environments?
- Which exact namespace bootstrap objects should be committed for `honcho` in `~/src/gitops` (namespace, network policy, ingress, quotas, pull secrets, etc.)?
- Which Honcho images/tags should be pinned in repo manifests for API, dashboard, and worker roles?
- Does Honcho require any PostgreSQL extensions beyond standard Postgres compatibility?
- Which exact Honcho environment variables are mandatory for self-hosted startup in our target version?
- Which ingress or exposure pattern should ServiceRadar prefer for Hermes/operator access to Honcho: private/internal Envoy Gateway, private/internal LoadBalancer-backed ingress, or another non-public entrypoint?
- Which exact internal IPs or existing private MetalLB pools can be reserved safely for Honcho without colliding with node or infrastructure addresses?
- Which final DNS shape should Honcho use on the local network: one hostname (`honcho.carverauto.dev`) with path-based routing, or separate dashboard/API hosts (`honcho.carverauto.dev` and `honcho-api.carverauto.dev`)?
- If the single-host model is kept, does Honcho expect the API to live under `/api` natively, or should the Gateway layer rewrite `/api/*` to `/` for the backend service?
- If a rewrite is needed, should the GitOps default switch to the rewrite variant route instead of the direct `/api` backend route?

## Validation

- Render or apply the Kubernetes manifests successfully.
- Verify the `honcho` namespace bootstrap succeeds.
- Verify the dedicated Honcho CNPG cluster reaches Ready with the Honcho database/user/secret bootstrap.
- Verify the HA Redis deployment reaches Ready and is reachable from Honcho pods.
- Verify Honcho migrations/initialization complete against CNPG.
- Verify the API, dashboard, and worker processes reach Ready and stay healthy.
- Verify a basic memory write/read path succeeds against the self-hosted deployment.
