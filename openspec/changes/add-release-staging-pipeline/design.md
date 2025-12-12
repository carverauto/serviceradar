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
- Tags generated: `sha-<commit>`, `v<version>`, `latest`, and image-specific static tags
- ✅ Semantic version tags (e.g., `v1.0.71`) now included via `expand_template` and workspace status

**Helm Chart (`helm/serviceradar/`):**
- ✅ Published to OCI registry: `oci://ghcr.io/carverauto/charts/serviceradar`
- `Chart.yaml` version synced with app version (updated by `cut-release.sh`)
- ✅ `values.yaml` uses `global.imageTag` with `latest` as default
- ✅ Helper templates for image tag/policy resolution

**ArgoCD (`k8s/argocd/applications/`):**
- `demo-prod.yaml` pointing to raw Git path `k8s/demo/prod` (uses Kustomize)
- ✅ `demo-staging.yaml` using OCI Helm chart with inline values

**Demo-Staging (`demo-staging` namespace):**
- ✅ Deployed via ArgoCD Helm chart
- ✅ Running with v1.0.71 images
- Uses `global.imageTag: "latest"` with `imagePullPolicy: Always`

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

### Decision 1: OCI Registry for Helm Charts
**Rationale:** OCI is the modern standard for Helm chart distribution. We already use ghcr.io for container images, so charts live alongside images. No need to modify docs deployment or maintain separate GitHub Pages branch.

**Alternatives Considered:**
- GitHub Pages: Would conflict with existing Docusaurus docs deployment, requires rebuilding docs on every chart update
- ChartMuseum: Requires hosting, more complex
- Artifact Hub: Good for discovery but still needs underlying storage

**Implementation:**
```yaml
# Added to .github/workflows/release.yml
- name: Publish Helm chart to OCI registry
  run: |
    echo "${GHCR_TOKEN}" | helm registry login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
    helm package helm/serviceradar
    helm push "serviceradar-${VERSION}.tgz" oci://ghcr.io/carverauto/charts
```

**Chart URL:** `oci://ghcr.io/carverauto/charts/serviceradar:1.0.70`

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
**Rationale:** ArgoCD Helm support is mature, allows value overrides per environment, and integrates well with OCI registries.

**Implementation:**
```yaml
# k8s/argocd/applications/demo-staging.yaml
spec:
  source:
    repoURL: ghcr.io/carverauto/charts
    chart: serviceradar
    targetRevision: "1.0.70"  # or "*" for latest
    helm:
      valueFiles:
        - values-demo-staging.yaml
```

Note: ArgoCD requires OCI URLs without the `oci://` prefix for Helm sources.

### Decision 4: Version Tag Strategy
**Rationale:** Use `v<VERSION>` tag (e.g., `v1.0.70`) as the primary release tag, with `latest` for dev convenience and `sha-<commit>` for immutability.

**Tag Priority:**
1. `v1.0.70` - Primary release tag
2. `sha-<commit>` - Immutable reference
3. `latest` - Development convenience (staging only)

**Implementation:**
- Modified `docker/images/container_tags.bzl` to add `version_tags` attribute to `immutable_push_tags` rule
- Modified `docker/images/push_targets.bzl` to generate version tag via `expand_template` using `{{STABLE_VERSION}}`
- Version is read from `VERSION` file via `scripts/workspace_status.sh` when `--stamp` is used
- The "vdev" tag is excluded when building without proper workspace status (local dev builds)

**Generated Tags (example):**
```
sha-486cbfcbc1027b4255e8287df1c7ced48402b1c4  # commit SHA
v1.0.70                                         # semantic version
latest                                          # static tag
sha-c30cd42eb275                                # short digest
```

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

### Trade-off: OCI registry visibility
**Accepted:** OCI charts in ghcr.io are less discoverable than GitHub Pages but provide better integration with existing GHCR authentication and image workflows.

### Decision 6: Helm Chart and Image Versioning Strategy
**Rationale:** Keep chart version in sync with app version (standard practice for charts in the same repo as the app). Image tags default to `latest` in values.yaml; deployments override via `global.imageTag`.

**Release updates required:**
1. `VERSION` file - app version
2. `helm/serviceradar/Chart.yaml` - chart version + appVersion (via `cut-release.sh`)

**Not updated on release:**
- `values.yaml` - keeps `appTag: "latest"` as default
- ArgoCD Applications override with `global.imageTag: "v1.0.71"` for specific versions

**Benefits:**
- Minimal files to update during release
- Flexible: local dev uses `latest`, deployments pin to specific versions
- Standard Helm versioning practice

## Migration Plan

### Phase 1: Helm Chart OCI Registry (DONE)
1. ~~Create gh-pages branch~~ Using OCI registry instead
2. Added helm package/push step to release.yml
3. Published chart: `oci://ghcr.io/carverauto/charts/serviceradar:1.0.71`
4. Updated `cut-release.sh` to bump Chart.yaml version automatically
5. Created ArgoCD repo credentials template

### Phase 2: Helm Values Modernization (DONE)
1. Added `global.imageTag` and `global.imagePullPolicy` to values.yaml
2. Set default `image.tags.appTag` to `latest`
3. Added helper templates for image tag/policy resolution
4. Updated key templates (core, web, datasvc, agent, poller, srql)

### Phase 3: Demo-Staging Setup (DONE)
1. Created demo-staging ArgoCD Application
2. Configured to use OCI Helm chart with inline values
3. Made Helm chart public in GHCR (no credentials needed)
4. Copied ghcr-io-cred image pull secret to demo-staging namespace
5. Successfully deployed demo-staging with v1.0.71 images

### Phase 4: GitOps Promoter (PENDING)
1. Install promoter CRDs
2. Configure staging->demo promotion
3. Integrate e2e test gate

### Phase 5: Full Pipeline (PENDING)
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
