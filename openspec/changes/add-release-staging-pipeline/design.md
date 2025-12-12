## Context

ServiceRadar releases currently follow a manual process:
1. Developer runs `scripts/cut-release.sh --version X.Y.Z`
2. Push triggers `.github/workflows/release.yml`
3. Bazel builds and pushes OCI images tagged with `sha-<commit>` and `latest`
4. Packages (deb/rpm) are uploaded to GitHub Releases
5. Manual Helm update to demo namespace (often forgotten or delayed)

This creates gaps where released images may not have been validated in a staging environment, leading to potential production issues.

### Current State Analysis

**OCI Images (`docker/images/push_targets.bzl:48-63`):**
- Tags generated: `sha-<commit>`, `latest`, and image-specific static tags
- Missing: Semantic version tags (e.g., `v1.0.70`)

**Helm Chart (`helm/serviceradar/`):**
- Lives only in Git repository
- `Chart.yaml` has static version `0.1.0`, appVersion `1.0.0`
- `values.yaml` uses hardcoded SHA tags: `sha-0933fd20c98038af196c35ea9f5cc95e3dc38909`
- No published chart repository

**ArgoCD (`k8s/argocd/applications/`):**
- Single app `demo-prod.yaml` pointing to raw Git path `k8s/demo/prod`
- Uses Kustomize, not Helm
- No staging application exists

**Staging (`k8s/demo/staging/`):**
- Kustomize overlay exists but namespace was deleted
- Hardcoded image SHA tags in kustomization.yaml

## Goals / Non-Goals

### Goals
- Automate staging deployment before any release
- Ensure images are tagged with semantic version for production use
- Publish Helm charts to a repository for external consumption
- Enable GitOps-driven promotion from staging to production
- Reduce manual release management overhead

### Non-Goals
- Multi-environment customer deployments (this is for demo/staging only)
- Breaking changes to existing Kustomize deployments (maintain compatibility)
- Complex approval workflows (start with automated promotion)

## Decisions

### Decision 1: GitHub Pages for Helm Chart Repository
**Rationale:** Simplest option with no additional infrastructure. GitHub Pages is free, integrates with the existing repo, and is widely used for Helm chart hosting.

**Alternatives Considered:**
- ChartMuseum: Requires hosting, more complex
- OCI Registry: Helm OCI support still maturing, less compatible with older ArgoCD
- Artifact Hub: Good for discovery but still needs underlying repo

**Implementation:**
```yaml
# .github/workflows/helm-release.yml
- uses: helm/chart-releaser-action@v1.6.0
  with:
    charts_dir: helm
  env:
    CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

### Decision 2: ArgoCD GitOps Promoter for Environment Promotion
**Rationale:** Native ArgoCD integration, declarative configuration, supports commit status gates for test validation.

**Alternatives Considered:**
- Argo Rollouts: More focused on canary/blue-green within a single app
- Flux: Would require migrating from ArgoCD
- Jenkins/custom: More maintenance overhead

**Key Resources:**
```yaml
apiVersion: promoter.argoproj.io/v1alpha1
kind: PromotionStrategy
metadata:
  name: serviceradar-release
spec:
  environments:
    - name: demo-staging
      source:
        type: registry
        registryRef: ghcr.io/carverauto/serviceradar-core
    - name: demo
      source:
        type: pull-request
      gates:
        - name: e2e-tests
          type: commit-status
```

### Decision 3: Helm-Based ArgoCD Applications
**Rationale:** ArgoCD Helm support is mature, allows value overrides per environment, and integrates well with chart repositories.

**Implementation:**
```yaml
# k8s/argocd/applications/demo-staging.yaml
spec:
  source:
    repoURL: https://carverauto.github.io/serviceradar
    chart: serviceradar
    targetRevision: "*"  # Latest chart version
    helm:
      valueFiles:
        - values-demo-staging.yaml
```

### Decision 4: Version Tag Strategy
**Rationale:** Use `v<VERSION>` tag (e.g., `v1.0.70`) as the primary release tag, with `latest` for dev convenience and `sha-<commit>` for immutability.

**Tag Priority:**
1. `v1.0.70` - Primary release tag
2. `sha-<commit>` - Immutable reference
3. `latest` - Development convenience (staging only)

### Decision 5: E2E Test Credentials via GitHub Environments
**Rationale:** Cannot expose kubectl/kubeadm API credentials to GitHub Actions. Instead, store application-level credentials in GitHub Secrets using deployment environments for isolation.

**Alternatives Considered:**
- Kubernetes API access: Security risk, requires kubeconfig in CI
- Fetch secrets via kubectl in CI: Same security risk
- Hardcoded test credentials: No environment separation, rotation nightmare

**Implementation:**
```yaml
# GitHub repository settings -> Environments
# Environment: demo-staging
#   Secrets:
#     - SERVICERADAR_ADMIN_PASSWORD
#     - SERVICERADAR_CORE_URL (e.g., https://staging.serviceradar.cloud)
#
# Environment: demo
#   Secrets:
#     - SERVICERADAR_ADMIN_PASSWORD
#     - SERVICERADAR_CORE_URL (e.g., https://demo.serviceradar.cloud)

# .github/workflows/e2e-tests.yml
jobs:
  e2e:
    environment: demo-staging  # or demo
    steps:
      - name: Run e2e tests
        env:
          ADMIN_PASSWORD: ${{ secrets.SERVICERADAR_ADMIN_PASSWORD }}
          CORE_URL: ${{ secrets.SERVICERADAR_CORE_URL }}
        run: |
          # Authenticate via HTTP API, not kubectl
          ./scripts/e2e-test.sh
```

**Benefits:**
- Environment-specific secrets with GitHub's built-in isolation
- No cluster credentials in CI
- Easy secret rotation via GitHub UI
- Audit log of environment deployments

## Risks / Trade-offs

### Risk: Helm chart version drift from app version
**Mitigation:** Automate Chart.yaml version update as part of `cut-release.sh`. Chart version matches release version.

### Risk: GitOps Promoter learning curve
**Mitigation:** Start with simple staging->demo flow. Add complex gates incrementally.

### Risk: Staging environment divergence
**Mitigation:** Use same Helm chart with minimal value overrides. Document differences clearly.

### Trade-off: GitHub Pages vs dedicated chart registry
**Accepted:** GitHub Pages has rate limits but sufficient for internal use. Can migrate later if needed.

## Migration Plan

### Phase 1: Helm Chart Repository (Week 1)
1. Create `gh-pages` branch with index.yaml
2. Add helm-release workflow
3. Publish initial chart version

### Phase 2: Image Version Tagging (Week 1)
1. Update push_targets.bzl for version tags
2. Modify release.yml to pass version
3. Verify with dry-run release

### Phase 3: Demo-Staging Setup (Week 2)
1. Create demo-staging ArgoCD Application
2. Deploy via Helm chart
3. Validate staging deployment works

### Phase 4: GitOps Promoter (Week 2-3)
1. Install promoter CRDs
2. Configure staging->demo promotion
3. Integrate e2e test gate

### Phase 5: Full Pipeline (Week 3)
1. Update release workflow for staged deployment
2. Test complete flow with pre-release
3. Document and train team

### Rollback Procedure
1. Revert to previous chart version via ArgoCD
2. Manual image tag override if needed
3. GitOps Promoter supports manual promotion bypass

## Resolved Questions

- **Demo-staging persistence:** Demo-staging is a persistent environment. It is the first environment where releases are validated before promotion to demo.

- **E2E test credentials:** E2E tests cannot use kubectl/kubeadm API directly (credentials not exposed to GitHub). Instead, use GitHub Secrets with deployment environments:
  - `demo-staging` environment: stores admin password, core service IP for staging
  - `demo` environment: stores admin password, core service IP for production demo
  - Tests authenticate via HTTP API using stored credentials

## Open Questions

- [ ] What specific e2e test scenarios should gate promotion? (API health, device ingestion, SRQL queries?)
- [ ] Should we support promoting to customer environments in the future?
