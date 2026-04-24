## 1. Discovery and design
- [ ] 1.1 Confirm the exact Honcho self-hosting container images, runtime roles, and required startup commands for the target version.
- [ ] 1.2 Extract the exact upstream Honcho environment variable names for database, Redis, URLs, secrets, and runtime mode.
- [ ] 1.3 Confirm that the first ServiceRadar deployment uses a dedicated Honcho CNPG cluster managed by the CNPG operator, not an existing database cluster.
- [ ] 1.4 Decide the HA Redis deployment pattern and persistence requirements.
- [ ] 1.5 Define the `honcho` namespace bootstrap objects and guardrails.
- [ ] 1.6 Document the Kubernetes deployment topology and startup sequence for the `honcho` namespace, API, dashboard, worker, HA Redis, and CNPG.

## 2. Namespace, CNPG, and secrets
- [ ] 2.1 Add the `honcho` namespace bootstrap manifests and any required namespace-scoped prerequisites in `~/src/gitops/k8s/honcho/`.
- [ ] 2.2 Add CNPG bootstrap manifests for a dedicated Honcho database cluster, role, and credentials in the GitOps repo.
- [ ] 2.3 Configure the Honcho CNPG cluster to use `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd` (or the pinned digest form used in demo manifests).
- [ ] 2.4 Add Kubernetes secrets/config in the `honcho` namespace for database connection settings, Redis connection settings, URLs, and auth/session secrets.
- [ ] 2.5 Keep CNPG and HA Redis internal-only by default.

## 3. Honcho runtime deployment
- [ ] 3.1 Add Kubernetes manifests for the Honcho API service in `~/src/gitops/k8s/honcho/base/`.
- [ ] 3.2 Add Kubernetes manifests for the Honcho dashboard/UI service in `~/src/gitops/k8s/honcho/base/`.
- [ ] 3.3 Add Kubernetes manifests for the Honcho worker/background processor in `~/src/gitops/k8s/honcho/base/` if required by the target version.
- [ ] 3.4 Add HA Redis deployment/dependency wiring in the GitOps repo required for self-hosted Honcho.
- [ ] 3.5 Encode migration/init behavior so Honcho initializes successfully against the dedicated CNPG cluster before steady-state startup.

## 4. Verification and docs
- [ ] 4.1 Validate rendered manifests, namespace bootstrap, and dependency wiring before cluster apply.
- [ ] 4.2 Deploy the stack in the `honcho` namespace and verify namespace, CNPG, HA Redis, API, dashboard, and worker readiness.
- [ ] 4.3 Verify Honcho can connect to the dedicated CNPG cluster using the configured credentials and complete any required migrations.
- [ ] 4.4 Verify a basic memory-provider workflow succeeds end-to-end.
- [ ] 4.5 Document the deployment and operator runbook, including required secrets, URLs, namespace objects, and validation commands.
- [ ] 4.6 Validate this change with `openspec validate add-honcho-memory-provider --strict`
