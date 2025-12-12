## Summary

**Status:** Mostly Complete - Demo-staging pipeline working, demo-prod migration pending

| Section | Status |
|---------|--------|
| 1. OCI Image Version Tagging | ✅ Complete |
| 2. Helm Chart OCI Registry | ✅ Complete |
| 3. Helm Values Modernization | ✅ Complete |
| 4. Demo-Staging ArgoCD App | ✅ Complete |
| 5. Environment Promotion | ✅ Simplified (manual PR) |
| 6. GitHub Environments & E2E | ✅ Complete |
| 7. Release Workflow | ✅ Complete (pending full test) |
| 8. Demo-Prod Migration | ⏳ Pending |
| 9. Helm CI/CD Quality Gates | ✅ Complete |

**Current State:**
- Demo-staging: Synced, Healthy (using OCI Helm chart v1.0.75)
- Demo-prod: Uses Kustomize, needs migration to Helm
- Promotion: Manual (PR or kubectl patch to update version)

---

## 1. OCI Image Version Tagging

- [x] 1.1 Update `docker/images/push_targets.bzl` to generate version tag via expand_template
- [x] 1.2 Modify `container_tags.bzl` to include semantic version (e.g., `v1.0.70`) via new `version_tags` attribute
- [x] 1.3 Verify `latest` tag is applied to all images during release builds (already present in static_tags)
- [x] 1.4 Version tag now read from VERSION file via workspace_status.sh (STABLE_VERSION)
- [x] 1.5 Test image tagging - verified tags include: sha-<commit>, v<version>, latest, sha-<digest>

## 2. Helm Chart OCI Registry Setup

- [x] 2.1 Push chart to OCI registry: `oci://ghcr.io/carverauto/charts/serviceradar:1.0.75` (includes all CNPG fixes + template fixes)
- [x] 2.2 Add helm package/push step to `.github/workflows/release.yml`
- [x] 2.3 Update `scripts/cut-release.sh` to bump Chart.yaml version and appVersion automatically
- [x] 2.4 Create ArgoCD repository credentials template (`k8s/argocd/config/ghcr-helm-repo.yaml`)
- [x] 2.5 Document Helm OCI registry URL and usage in README

## 3. Helm Values Modernization

- [x] 3.1 Add `global.imageTag` override for consistent tag across all services
- [x] 3.2 Add `global.imagePullPolicy` defaulting to `IfNotPresent`
- [x] 3.3 Set default `image.tags.appTag` to `latest` (deployments override via `global.imageTag`)
- [x] 3.4 Add helper templates `serviceradar.imageTag` and `serviceradar.imagePullPolicy`
- [x] 3.5 Update key templates (core, web, datasvc, agent, poller, srql) to use helpers
- [x] 3.6 Fix CNPG secret name to use dynamic cluster name (`$cnpgClusterName-ca`) in core.yaml, srql.yaml, db-event-writer.yaml
- [x] 3.7 Fix CNPG host to use dynamic cluster name (`$cnpgClusterName-rw`) in core.yaml, db-event-writer.yaml, config files
- [x] 3.8 Update remaining templates to use helpers (flowgger, mapper, zen, sync, trapd, snmp-checker, faker, rperf-checker, otel)
- [x] 3.9 Fix db-event-writer-config.yaml template whitespace issue (malformed apiVersion line)
- [x] 3.10 Fix db-event-writer.yaml duplicate volume/volumeMount definitions

## 4. Demo-Staging ArgoCD Application

- [x] 4.1 Create `k8s/argocd/applications/demo-staging.yaml` ArgoCD Application
- [x] 4.2 Configure Application to use Helm chart from OCI registry (`ghcr.io/carverauto/charts`)
- [x] 4.3 Set up inline values for staging-specific configuration (imagePullPolicy: Always)
- [x] 4.4 Configure `demo-staging` namespace creation via ArgoCD syncPolicy
- [x] 4.5 ArgoCD repo credentials not needed - Helm chart made public in GHCR
- [x] 4.6 Build and push v1.0.72 images with semantic version tags
- [x] 4.7 Test ArgoCD sync for demo-staging deployment - chart 1.0.75 with all fixes, Sync: Synced, Health: Healthy

## 5. Environment Promotion (SIMPLIFIED)

**Note:** GitOps Promoter with Source Hydrator was evaluated but removed due to complexity.
The Source Hydrator requires specific credential configurations for write operations that
proved difficult to set up with GitHub Apps. A simpler manual PR-based promotion is now used.

- [x] 5.1 ~~Install ArgoCD Source Hydrator~~ (removed - too complex)
- [x] 5.2 ~~Install GitOps Promoter CRDs~~ (removed - not needed without hydrator)
- [x] 5.3 ~~Create PromotionStrategy~~ (removed)
- [x] 5.4 ~~Create ArgoCDCommitStatus~~ (removed)
- [x] 5.5 ~~Create hydrator ArgoCD Applications~~ (removed)
- [x] 5.6 Create environment-specific values files (`helm/serviceradar/values-demo-staging.yaml`, `values-demo.yaml`)
- [N/A] 5.7 ~~Document promoter workflow~~ (removed - k8s/gitops-promoter/ deleted)
- [N/A] 5.8 ~~Create GitHub App~~ (not needed for simplified approach)
- [N/A] 5.9 ~~Create environment branches~~ (not needed)
- [N/A] 5.10 ~~Apply ScmProvider/GitRepository~~ (not needed)

**Current Promotion Workflow:**
1. Release updates chart in OCI registry
2. ArgoCD auto-syncs demo-staging
3. E2E tests validate staging deployment
4. Manual PR or kubectl patch to promote version to demo-prod
5. ArgoCD syncs demo-prod

## 6. GitHub Environments and E2E Test Integration

- [x] 6.1 Create GitHub Environment `demo-staging` with secrets (placeholder values set)
- [x] 6.2 Create GitHub Environment `demo` with secrets
- [x] 6.3 Create `scripts/e2e-test.sh` that authenticates via HTTP API (not kubectl)
- [x] 6.4 Create `.github/workflows/e2e-tests.yml` workflow using environment secrets
- [x] 6.5 Implement e2e test scenarios (API health, login, basic queries)
- [x] 6.6 ~~Configure test results to update CommitStatus for promoter~~ (N/A - promoter removed)
- [x] 6.7 Define minimum passing criteria for promotion approval (all tests must pass)

## 7. Release Workflow Refactoring

- [x] 7.1 Add Helm chart publish step to release.yml
- [x] 7.2 Split release.yml into stages: build -> deploy-staging -> test -> promote -> release
      (Note: Staging is split via separate e2e-tests.yml workflow that runs after release)
- [x] 7.3 Add staging deployment step before package publishing
      (Note: ArgoCD auto-syncs staging when Helm chart is published; e2e-tests run after)
- [x] 7.4 Update `scripts/cut-release.sh` to support `--skip-staging` for hotfixes
- [x] 7.5 Add rollback procedure documentation
- [ ] 7.6 Test full pipeline with a pre-release version

## 8. ArgoCD Demo Application Update

**Note:** Demo-prod currently uses Kustomize (`k8s/demo/prod`) and has a sync error.
Future work to migrate demo-prod to Helm chart like demo-staging.

- [ ] 8.1 Update `k8s/argocd/applications/demo-prod.yaml` to use Helm chart from OCI registry
- [ ] 8.2 Configure demo to pull specific version tag (not `*`) for stability
- [N/A] 8.3 ~~Set up ApplicationSet or sync waves~~ (not needed for current scope)
- [ ] 8.4 Verify demo deployment pulls promoted version correctly

## 9. Helm Chart CI/CD Quality Gates

- [x] 9.1 Add `helm lint` step to CI workflow (runs on helm/ path changes only)
- [x] 9.2 Configure path filter in workflow to scope lint to `helm/**` changes
- [x] 9.3 Add `helm template` validation step to verify chart renders correctly
- [ ] 9.4 Consider adding chart testing with `ct lint` from chart-testing tool
