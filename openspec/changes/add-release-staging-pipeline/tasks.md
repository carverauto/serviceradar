## 1. OCI Image Version Tagging

- [ ] 1.1 Update `docker/images/push_targets.bzl` to accept version tag from release workflow
- [ ] 1.2 Modify `container_tags.bzl` to include semantic version (e.g., `v1.0.70`) when provided
- [ ] 1.3 Verify `latest` tag is applied to all images during release builds
- [ ] 1.4 Update `.github/workflows/release.yml` to pass `--tag v$VERSION` to image push step
- [ ] 1.5 Test image tagging with a dry-run release

## 2. Helm Chart Repository Setup

- [ ] 2.1 Create `.github/workflows/helm-release.yml` workflow for chart publishing
- [ ] 2.2 Configure GitHub Pages for chart hosting (branch: `gh-pages`, path: `/charts`)
- [ ] 2.3 Add `helm package` and `helm repo index` steps to workflow
- [ ] 2.4 Update `helm/serviceradar/Chart.yaml` with versioning scheme matching releases
- [ ] 2.5 Create script to update Chart.yaml version from VERSION file
- [ ] 2.6 Document Helm repository URL and usage in README

## 3. Helm Values Modernization

- [ ] 3.1 Update `helm/serviceradar/values.yaml` to use `image.tag` defaulting to chart appVersion
- [ ] 3.2 Add `global.imageTag` override for consistent tag across all services
- [ ] 3.3 Add `image.pullPolicy` defaulting to `IfNotPresent`, override to `Always` for staging
- [ ] 3.4 Create `values-demo-staging.yaml` with `pullPolicy: Always` and staging overrides
- [ ] 3.5 Update templates to respect `global.imageTag` and `image.pullPolicy`

## 4. Demo-Staging ArgoCD Application

- [ ] 4.1 Create `k8s/argocd/applications/demo-staging.yaml` ArgoCD Application
- [ ] 4.2 Configure Application to use Helm chart from chart repository
- [ ] 4.3 Set up values file overlay for staging-specific configuration
- [ ] 4.4 Ensure `demo-staging` namespace creation via ArgoCD syncPolicy
- [ ] 4.5 Test ArgoCD sync for demo-staging deployment

## 5. GitOps Promoter Integration

- [ ] 5.1 Install and configure ArgoCD GitOps Promoter CRDs
- [ ] 5.2 Create `CommitStatus` resource for demo-staging health checks
- [ ] 5.3 Create `PromotionStrategy` defining demo-staging -> demo -> release flow
- [ ] 5.4 Configure e2e test job as promotion gate
- [ ] 5.5 Add `ChangeTransferPolicy` for automatic demo promotion on staging success
- [ ] 5.6 Document promoter workflow and manual override procedures

## 6. GitHub Environments and E2E Test Integration

- [ ] 6.1 Create GitHub Environment `demo-staging` with secrets:
  - `SERVICERADAR_ADMIN_PASSWORD` - admin password for staging
  - `SERVICERADAR_CORE_URL` - e.g., `https://staging.serviceradar.cloud`
- [ ] 6.2 Create GitHub Environment `demo` with secrets:
  - `SERVICERADAR_ADMIN_PASSWORD` - admin password for demo
  - `SERVICERADAR_CORE_URL` - e.g., `https://demo.serviceradar.cloud`
- [ ] 6.3 Create `scripts/e2e-test.sh` that authenticates via HTTP API (not kubectl)
- [ ] 6.4 Create `.github/workflows/e2e-tests.yml` workflow using environment secrets
- [ ] 6.5 Implement e2e test scenarios (API health, login, basic queries)
- [ ] 6.6 Configure test results to update CommitStatus for promoter
- [ ] 6.7 Define minimum passing criteria for promotion approval

## 7. Release Workflow Refactoring

- [ ] 7.1 Split release.yml into stages: build -> deploy-staging -> test -> promote -> release
- [ ] 7.2 Add staging deployment step before package publishing
- [ ] 7.3 Add promotion wait step with configurable timeout
- [ ] 7.4 Update `scripts/cut-release.sh` to support `--skip-staging` for hotfixes
- [ ] 7.5 Add rollback procedure documentation
- [ ] 7.6 Test full pipeline with a pre-release version

## 8. ArgoCD Demo Application Update

- [ ] 8.1 Update `k8s/argocd/applications/demo-prod.yaml` to use Helm chart repository
- [ ] 8.2 Configure demo to pull specific version tag (not latest) for stability
- [ ] 8.3 Set up ApplicationSet or sync waves if needed for ordered deployments
- [ ] 8.4 Verify demo deployment pulls promoted version correctly
