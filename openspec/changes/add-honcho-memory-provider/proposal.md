# Change: Add self-hosted Honcho memory provider backed by CNPG

## Why

- ServiceRadar needs a first-class way to self-host Honcho so memory features can run inside the existing Kubernetes footprint instead of depending on an external managed database.
- The repo already standardizes on CNPG for PostgreSQL workloads and already ships a custom CNPG image at `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd`, which is the same image used for ServiceRadar CNPG clusters.
- The Honcho self-hosting guidance expects persistent PostgreSQL storage plus supporting runtime services, so the deployment needs to be modeled explicitly rather than treated as an ad hoc sidecar.
- Honcho self-hosting also depends on additional runtime configuration and supporting services such as Redis, secrets, and API/UI wiring, which should be captured in spec-first form before implementation.

## What Changes

- Add a self-hosted Honcho deployment pattern for Kubernetes that uses a dedicated CNPG-backed PostgreSQL cluster for durable memory/application state.
- Deploy the full Honcho stack into a dedicated Kubernetes namespace named `honcho`, with Honcho application services, Redis, and the Honcho CNPG cluster all living in that namespace.
- Require the Honcho database cluster to use the existing ServiceRadar CNPG custom image `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd` (or the corresponding pinned digest form in demo manifests) and be managed by the CNPG operator as a new cluster, not by reusing an existing database cluster.
- Define the supporting Honcho runtime components: API service, dashboard/UI service, worker/background processing, an HA Redis deployment, Kubernetes secrets, and internal service wiring.
- Define operator-facing configuration for database credentials, Redis connectivity, public/base URLs, auth/session secrets, namespace-scoped deployment, and startup ordering so the stack can be deployed repeatably in demo and future environments.
- Document validation expectations for namespace bootstrap, database initialization/migrations, CNPG readiness, HA Redis readiness, and end-to-end Honcho startup against the self-hosted stack.

## Impact

- Affected specs: `honcho-memory-provider`
- Affected code:
  - `openspec/changes/add-honcho-memory-provider/`
  - GitOps manifests in `~/src/gitops/k8s/honcho/`
  - GitOps Argo CD application wiring in `~/src/gitops/k8s/honcho/argocd-application.yaml`
  - HA Redis values and dependency wiring in the GitOps repo
  - secrets/config management for Honcho runtime env vars within the `honcho` namespace
  - deployment/runbook documentation for self-hosting Honcho in the `honcho` namespace
