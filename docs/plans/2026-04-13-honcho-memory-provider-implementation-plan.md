# Honcho Memory Provider Implementation Plan

> For Hermes: Use subagent-driven-development skill to implement this plan task-by-task.

Goal: Deploy Honcho as a self-hosted memory provider in a dedicated `honcho` namespace with a dedicated CNPG-managed Postgres cluster, HA Redis, explicit startup sequencing, and a documented end-to-end verification path.

Architecture: Keep the Kubernetes deployment in the GitOps repo under `~/src/gitops/k8s/honcho/` instead of folding it into the ServiceRadar demo manifests or reusing an existing database cluster. Use the existing cluster-scoped CNPG operator as a prerequisite, provision a new CNPG `Cluster` in `honcho`, deploy Honcho API/dashboard/worker as explicit Deployments or Jobs with upstream env var names, and manage HA Redis via a pinned external Helm chart with its values committed in the GitOps repo.

Tech Stack: Kubernetes, Kustomize, Argo CD, CloudNativePG, ServiceRadar CNPG custom image (`registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd`), Bitnami Redis Helm chart in HA mode, Harbor image pull secrets, jj, fj, OpenSpec.

---

## Task 0: Create tracking scaffolding before changing manifests

Objective: Put the work on a jj change with a Forgejo issue before editing Kubernetes files.

Files:
- Create: none
- Modify: none
- Output artifacts: Forgejo issue, jj change

Step 1: Sync local repo state
Run:
`jj status`
`jj git fetch --remote origin`
Expected: current working copy state is clear and remote bookmarks are up to date.

Step 2: Create the Forgejo issue
Run:
`fj issue create -R origin --no-template "Add self-hosted Honcho memory provider in dedicated honcho namespace" --body-file /tmp/honcho-memory-provider-issue.md`
Issue body should summarize:
- dedicated `honcho` namespace
- dedicated CNPG cluster managed by the existing operator
- HA Redis requirement
- no reuse of existing database clusters
- implementation must follow `openspec/changes/add-honcho-memory-provider/`

Step 3: Create the jj change
Run:
`jj new -m "feat: add honcho self-hosted memory stack"`
Expected: a new working change is created.

Step 4: Link the issue in the change description
Run:
`jj describe -m "feat: add honcho self-hosted memory stack

Refs: <forgejo-issue-url>"`
Expected: the jj change points back to the issue.

---

## Task 1: Confirm the upstream Honcho deployment contract and pin versions

Objective: Remove the remaining upstream unknowns before writing manifests so we do not invent env vars, startup commands, or image names.

Files:
- Modify: `openspec/changes/add-honcho-memory-provider/design.md` only if new facts close current open questions
- Create: `/tmp/honcho-self-hosting-notes.md` during investigation
- Output artifact: exact image names/tags, env var names, startup commands, and migration command list

Step 1: Extract exact Honcho env var names and startup commands
Use the Honcho README/self-hosting docs and capture the exact names for:
- database connection env vars
- Redis connection env vars
- public/base URL env vars
- auth/session secret env vars
- runtime mode env vars
- migration/init commands
- API/dashboard/worker image names and tags

Step 2: Record the contract in a short scratch note
Write a temporary note containing:
- image names/tags
- command/args for API/dashboard/worker
- required env vars with exact spelling
- required readiness endpoints if documented

Step 3: Close OpenSpec gaps if needed
If the upstream docs resolve any current open questions in `openspec/changes/add-honcho-memory-provider/design.md`, patch the design doc before proceeding.

Step 4: Verify that the plan is now concrete
Expected outcome:
- no guessed Honcho env var names remain
- no guessed Honcho image names remain
- migration strategy is known before manifest work starts

---

## Task 2: Create the `~/src/gitops/k8s/honcho/base` namespace-scoped scaffold

Objective: Establish a clean repo location for everything that lives in the dedicated `honcho` namespace.

Files:
- Create: `~/src/gitops/k8s/honcho/base/kustomization.yaml`
- Create: `~/src/gitops/k8s/honcho/base/namespace.yaml`
- Create: `~/src/gitops/k8s/honcho/base/README.md`
- Create: `~/src/gitops/k8s/honcho/base/secrets.yaml`
- Create: `~/src/gitops/k8s/honcho/base/network-policy.yaml`

Step 1: Create the directory structure
Create:
- `~/src/gitops/k8s/honcho/base/`

Step 2: Add the namespace manifest
Model it after:
- `k8s/srql-fixtures/namespace.yaml`
- `k8s/demo/staging/namespace.yaml`

Create `~/src/gitops/k8s/honcho/base/namespace.yaml` with:
- `kind: Namespace`
- `metadata.name: honcho`
- labels for `name: honcho`
- an `environment` label only if we decide the namespace is environment-specific

Step 3: Add the base kustomization
Create `~/src/gitops/k8s/honcho/base/kustomization.yaml` with `resources:` entries for:
- `namespace.yaml`
- `secrets.yaml`
- `cnpg-cluster.yaml`
- `network-policy.yaml`
- `honcho-migrate-job.yaml`
- `honcho-api.yaml`
- `honcho-dashboard.yaml`
- `honcho-worker.yaml`

Do not include Redis here if Redis is managed by external Helm through Argo CD.

Step 4: Add placeholder secrets manifest
Create `~/src/gitops/k8s/honcho/base/secrets.yaml` following the placeholder-secret pattern in `k8s/demo/base/secrets.yaml` and `k8s/srql-fixtures/cnpg-test-credentials.yaml`.
Include placeholder objects for:
- `registry-carverauto-dev-cred` in namespace `honcho` if Honcho images are pulled from Harbor
- `honcho-db-credentials`
- `honcho-db-superuser-credentials` if needed
- `honcho-secrets` for app/runtime/auth/session values

Use `stringData` and `CHANGEME` placeholders. Do not commit live secrets.

Step 5: Add namespace README
Create `~/src/gitops/k8s/honcho/base/README.md` documenting:
- namespace purpose
- CNPG operator prerequisite (`k8s/operator/README.md`)
- secret creation order
- kustomize apply commands
- Redis deployment dependency

Step 6: Add a baseline NetworkPolicy
Create `~/src/gitops/k8s/honcho/base/network-policy.yaml` with an internal-first policy:
- allow same-namespace traffic
- allow DNS egress to kube-system
- allow egress to Kubernetes API only if required
- do not expose CNPG or Redis externally

Use `helm/serviceradar/templates/network-policy.yaml` as the behavior reference, but commit a plain manifest for `honcho`.

Step 7: Verify the scaffold
Run:
`kubectl kustomize k8s/honcho/base >/tmp/honcho-base-rendered.yaml`
Expected: the base renders without missing-file errors.

---

## Task 3: Add a dedicated Honcho CNPG cluster in the `honcho` namespace

Objective: Provision a fresh CNPG cluster for Honcho instead of reusing any existing ServiceRadar database cluster.

Files:
- Create: `~/src/gitops/k8s/honcho/base/cnpg-cluster.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/kustomization.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/secrets.yaml`

Step 1: Model the CNPG manifest from existing repo examples
Use these as references:
- `k8s/demo/base/cnpg-cluster.yaml`
- `k8s/srql-fixtures/cnpg-cluster.yaml`

Step 2: Create `~/src/gitops/k8s/honcho/base/cnpg-cluster.yaml`
Use:
- `apiVersion: postgresql.cnpg.io/v1`
- `kind: Cluster`
- `metadata.name: honcho-cnpg` (or another explicit Honcho-specific name)
- `metadata.namespace: honcho`
- `spec.imageName: registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd`
- `imagePullSecrets: [registry-carverauto-dev-cred]`
- dedicated storage size/class values
- dedicated `bootstrap.initdb.database` and `owner`
- `secret.name: honcho-db-credentials`
- internal-only posture by relying on CNPG’s default `-rw` service

Do not create a LoadBalancer service for Postgres.

Step 3: Keep CNPG bootstrap minimal
Unless Honcho docs prove otherwise, do not cargo-cult all ServiceRadar extensions into the Honcho DB.
Default to standard Postgres bootstrap and add extensions only if Honcho actually requires them.

Step 4: Add credentials secrets
Ensure `~/src/gitops/k8s/honcho/base/secrets.yaml` includes:
- `honcho-db-credentials`
- optional superuser secret if migration/init flow needs elevated access

Step 5: Add README commands for first-time bootstrap
Document commands such as:
`kubectl apply -f k8s/honcho/base/namespace.yaml`
`kubectl apply -f k8s/honcho/base/secrets.yaml`
`kubectl apply -f k8s/honcho/base/cnpg-cluster.yaml`

Step 6: Verify CNPG manifest render
Run:
`kubectl apply --dry-run=server -f k8s/honcho/base/cnpg-cluster.yaml`
Expected: the cluster validates against the CNPG CRD.

---

## Task 4: Add HA Redis as a pinned external dependency with in-repo values

Objective: Deploy Redis in HA mode without hand-writing Sentinel/replication manifests from scratch.

Files:
- Create: `~/src/gitops/k8s/honcho/redis-values.yaml`
- Create: `~/src/gitops/k8s/honcho/argocd-application.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/README.md`

Step 1: Use a concrete HA Redis implementation
Adopt the Bitnami Redis chart in replication + Sentinel mode as the default implementation unless the user overrides this decision.
Chart repo:
`https://charts.bitnami.com/bitnami`
Chart name:
`redis`

Step 2: Create `~/src/gitops/k8s/honcho/redis-values.yaml`
Set values for:
- namespace `honcho`
- auth secret wiring (do not commit the real password)
- Sentinel enabled
- replica count > 1
- persistence enabled
- internal-only Service type(s)
- resource requests/limits
- `global.storageClass` only if the cluster requires it

Step 3: Keep Redis credentials in `~/src/gitops/k8s/honcho/base/secrets.yaml`
Add the Redis password or existingSecret reference in a way the chart can consume without committing credentials.

Step 4: Add Argo CD application wiring
Create `~/src/gitops/k8s/honcho/argocd-application.yaml` as a multi-source app modeled after `k8s/argocd/applications/demo-staging.yaml`:
- source 1: this repo path `~/src/gitops/k8s/honcho/base`
- source 2: Helm chart source for Bitnami Redis using `$values/k8s/honcho/redis-values.yaml`
- destination namespace: `honcho`
- sync option `CreateNamespace=true`
- ignore-differences for CNPG PVC status if needed

Step 5: Add manual verification commands to the README
Document:
`helm repo add bitnami https://charts.bitnami.com/bitnami`
`helm template honcho-redis bitnami/redis -n honcho -f k8s/honcho/redis-values.yaml >/tmp/honcho-redis-rendered.yaml`

Step 6: Verify Redis render
Run:
`helm template honcho-redis bitnami/redis -n honcho -f k8s/honcho/redis-values.yaml >/tmp/honcho-redis-rendered.yaml`
Expected: chart renders successfully with no missing values.

---

## Task 5: Add the Honcho migration/init job and shared config/secret contract

Objective: Make startup ordering explicit so Honcho does not report healthy before DB and Redis are ready.

Files:
- Create: `~/src/gitops/k8s/honcho/base/honcho-migrate-job.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/secrets.yaml`
- Optionally create: `~/src/gitops/k8s/honcho/base/configmap.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/kustomization.yaml`

Step 1: Decide whether env belongs in Secret or ConfigMap
Use:
- Secret for passwords, tokens, signing keys, session secrets, DSNs if they contain credentials
- ConfigMap only for non-sensitive public URLs and feature flags

If both are needed, create `~/src/gitops/k8s/honcho/base/configmap.yaml`.

Step 2: Create `honcho-migrate-job.yaml`
Use the exact upstream Honcho image and command discovered in Task 1.
The job should:
- run in namespace `honcho`
- wait for CNPG `honcho-cnpg-rw` service DNS to resolve/reach readiness
- wait for Redis service readiness if migrations require it
- run the documented Honcho migration/init command once
- exit non-zero on failure

Step 3: Use exact upstream env var names
Populate the Job with the exact env var names from Task 1.
Do not invent local aliases like `HONCHO_DB_URL` unless upstream says so.

Step 4: Add restart/backoff behavior appropriate for init jobs
Use a `backoffLimit` and clear logs; do not let migration failure be silent.

Step 5: Verify Job render
Run:
`kubectl apply --dry-run=server -f k8s/honcho/base/honcho-migrate-job.yaml`
Expected: manifest validates and references only existing config objects.

---

## Task 6: Add the Honcho API deployment and service

Objective: Bring up the backend with explicit readiness and namespace-local dependencies.

Files:
- Create: `~/src/gitops/k8s/honcho/base/honcho-api.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/kustomization.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/secrets.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/configmap.yaml` if used

Step 1: Create the Deployment and Service
Include:
- `Deployment` for the Honcho API
- `Service` exposing the API on a ClusterIP service inside `honcho`
- `imagePullSecrets: [registry-carverauto-dev-cred]` when needed

Step 2: Wire exact env vars from upstream docs
Populate:
- database connection env vars pointing to `honcho-cnpg-rw.honcho.svc`
- Redis connection env vars pointing to the HA Redis service DNS
- public/base URL values for internal-first operation
- auth/session secret env vars from `honcho-secrets`

Step 3: Add readiness/liveness probes
Use upstream-documented health endpoints if available.
If upstream does not document one, choose the smallest safe HTTP/TCP probe and document the rationale in `~/src/gitops/k8s/honcho/base/README.md`.

Step 4: Keep startup dependent on migrations
Do not assume the API can safely self-migrate. The main deployment should depend on the migration job having succeeded operationally.

Step 5: Verify render
Run:
`kubectl apply --dry-run=server -f k8s/honcho/base/honcho-api.yaml`
Expected: API manifest validates.

---

## Task 7: Add the Honcho dashboard deployment and service

Objective: Bring up the UI separately from the backend so the stack matches the self-hosted architecture described in the OpenSpec.

Files:
- Create: `~/src/gitops/k8s/honcho/base/honcho-dashboard.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/kustomization.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/secrets.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/configmap.yaml` if used

Step 1: Create the Deployment and Service
Include:
- `Deployment` for the dashboard/UI
- `Service` exposing the UI internally in `honcho`

Step 2: Wire API URL and any UI secrets/config
Use the exact upstream env var names from Task 1.
Point the dashboard at the internal API service, not an external ingress URL.

Step 3: Add readiness probe
Use the UI’s documented health or HTTP endpoint.

Step 4: Verify render
Run:
`kubectl apply --dry-run=server -f k8s/honcho/base/honcho-dashboard.yaml`
Expected: dashboard manifest validates.

---

## Task 8: Add the Honcho worker deployment if the target version requires it

Objective: Model background processing explicitly rather than assuming the API pod does everything.

Files:
- Create: `~/src/gitops/k8s/honcho/base/honcho-worker.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/kustomization.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/secrets.yaml`
- Modify: `~/src/gitops/k8s/honcho/base/configmap.yaml` if used

Step 1: Confirm worker necessity from Task 1
If the target Honcho version packages background processing separately, create the worker deployment. If not, keep the file but document that it is intentionally omitted and remove it from `kustomization.yaml`.

Step 2: Wire DB/Redis/auth env vars
Use the same secret/config sources as the API, with the exact upstream variable names.

Step 3: Add failure visibility
The worker should have clear logs and a readiness model appropriate for queue consumers.
If no readiness probe exists, rely on pod status plus logs and document the limitation.

Step 4: Verify render
Run:
`kubectl apply --dry-run=server -f k8s/honcho/base/honcho-worker.yaml`
Expected: worker manifest validates, or the omission is explicitly documented.

---

## Task 9: Add Argo CD wiring, optional Honcho exposure, and end-to-end deploy docs

Objective: Make the stack reproducible through the repo’s existing GitOps patterns and provide a controlled way for Hermes/operators to reach Honcho without exposing CNPG or Redis.

Files:
- Create: `~/src/gitops/k8s/honcho/argocd-application.yaml`
- Create: `~/src/gitops/k8s/honcho/base/ingress.yaml` if ingress is chosen for Hermes/operator access
- Modify: `~/src/gitops/k8s/honcho/base/kustomization.yaml` when ingress is enabled
- Modify: `~/src/gitops/k8s/honcho/base/README.md`
- Optionally modify: `k8s/argocd/base/README.md`

Step 1: Create the Argo CD application
Model it after:
- `k8s/argocd/applications/demo-prod.yaml`
- `k8s/argocd/applications/demo-staging.yaml`

The app should:
- target namespace `honcho`
- create the namespace if absent
- include the repo `~/src/gitops/k8s/honcho/base` source
- include the external Helm source for Redis values
- avoid pruning storage resources in a way that surprises operators

Step 2: Add a durable private-network exposure path for Hermes/operator access
Choose a controlled access pattern and document it explicitly:
- preferred durable rollout: internal Envoy Gateway / Gateway API route backed by a private/internal LoadBalancer IP
- candidate internal VIP source from live cluster state: existing MetalLB `k3s-lan-pool` (`192.168.6.80-192.168.6.95`)
- suggested starting Honcho VIP: `192.168.6.82` after explicit verification that it remains unused
- suggested starting DNS shape:
  - hostname: `honcho.carverauto.dev`
  - dashboard/UI: `/`
  - API: `/api`
- if Honcho upstream requires separate hosts instead, split API onto a second hostname later
- suggested starting cert-manager secret / issuer:
  - secret: `honcho-internal-tls`
  - issuer: `carverauto-issuer`
- alternative durable rollout: internal-only ingress backed by a private/internal LoadBalancer IP
- temporary testing only: `kubectl port-forward`

Rules:
- expose only the Honcho API and/or dashboard
- do not expose CNPG
- do not expose Redis
- avoid assigning a broad public 80/443 endpoint by default
- keep durable exposure opt-in rather than part of the default bootstrap path

Step 3: Document bootstrap order in README
Document:
1. CNPG operator is installed once per cluster (`k8s/operator/README.md`)
2. commit the Honcho GitOps manifests under `~/src/gitops/k8s/honcho/`
3. create/copy `registry-carverauto-dev-cred` into `honcho` through the GitOps-compatible secret flow you choose
4. create the non-committed runtime secrets/config inputs required by Honcho
5. apply or sync the Argo CD app
6. wait for CNPG, Redis, migration job, API, dashboard, worker
7. enable the private/internal Gateway or ingress path for Hermes/operator access through GitOps-managed manifests

Step 4: Document status commands
Add commands:
`kubectl get applications -n argocd honcho -o yaml`
`kubectl get pods -n honcho`
`kubectl get cluster -n honcho`
`kubectl get jobs -n honcho`
`kubectl logs -n honcho job/honcho-migrate`
`kubectl get gateway -n honcho`
`kubectl get httproute -n honcho`

---

## Task 10: Validate the stack incrementally before first full deploy

Objective: Catch manifest and dependency problems before doing the first real cluster rollout.

Files:
- Modify: `~/src/gitops/k8s/honcho/base/README.md`
- Modify: `openspec/changes/add-honcho-memory-provider/tasks.md` as work completes

Step 1: Validate OpenSpec again
Run:
`openspec validate add-honcho-memory-provider --strict`
Expected: change remains valid after any design/spec touchups.

Step 2: Validate local manifest rendering
Run:
`kubectl kustomize k8s/honcho/base >/tmp/honcho-base-rendered.yaml`
`kubectl apply --dry-run=server -f /tmp/honcho-base-rendered.yaml`
Expected: namespace-scoped manifests validate.

Step 3: Validate Redis render
Run:
`helm template honcho-redis bitnami/redis -n honcho -f k8s/honcho/redis-values.yaml >/tmp/honcho-redis-rendered.yaml`
`kubectl apply --dry-run=server -f /tmp/honcho-redis-rendered.yaml`
Expected: Redis chart validates with the selected values.

Step 4: Do the first controlled deploy
Run:
`kubectl apply -k k8s/honcho/base`
`helm upgrade --install honcho-redis bitnami/redis -n honcho -f k8s/honcho/redis-values.yaml`
Expected order:
- namespace exists
- secrets exist
- CNPG cluster starts
- Redis starts
- migrate job succeeds
- API/dashboard/worker become Ready

Step 5: Validate CNPG readiness
Run:
`kubectl get cluster -n honcho`
`kubectl get pods -n honcho -l cnpg.io/cluster=honcho-cnpg`
Expected: CNPG cluster is healthy and primary service exists.

Step 6: Validate Redis readiness
Run:
`kubectl get pods -n honcho -l app.kubernetes.io/name=redis`
Expected: Redis pods and Sentinel sidecars are Ready.

Step 7: Validate Honcho startup
Run:
`kubectl get pods -n honcho`
`kubectl logs -n honcho deploy/honcho-api --tail=100`
`kubectl logs -n honcho deploy/honcho-dashboard --tail=100`
Expected: application services start without DB/Redis connection errors.

Step 8: Validate the first end-to-end memory flow
Use either the documented Honcho API route or UI workflow from Task 1 and confirm:
- dashboard reachable through port-forward or ingress
- API reachable by Hermes through the chosen controlled exposure path
- API can write a test memory entry
- API can read that memory entry back

Step 9: Update the OpenSpec checklist
Mark completed items in:
`openspec/changes/add-honcho-memory-provider/tasks.md`

---

## Task 11: Prepare review and handoff

Objective: Leave the implementation in a reviewable state with clear docs and no hidden local knowledge.

Files:
- Modify: `~/src/gitops/k8s/honcho/base/README.md`
- Modify: `openspec/changes/add-honcho-memory-provider/tasks.md`
- Modify: any newly created Kubernetes files only as needed for cleanup

Step 1: Review for hard-coded secrets or guessed names
Check that:
- no real credentials were committed
- no guessed Honcho env var names remain
- no guessed image names remain

Step 2: Review diffs
Run:
`jj diff --summary`
Expected: only Honcho-related repo paths changed.

Step 3: Prepare review notes
Summarize:
- namespace layout
- dedicated CNPG cluster
- HA Redis chart choice and pinned version
- exact secrets operators must create
- verification commands

Step 4: Final verification
Run:
`openspec validate add-honcho-memory-provider --strict`
Expected: valid change before requesting review.
