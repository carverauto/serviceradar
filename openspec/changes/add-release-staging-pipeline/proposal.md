# Change: Add Release Staging Pipeline with GitOps Promotion

## Why

The current release process requires significant manual intervention: building images, manually deploying to demo, testing, then cutting the release. This creates risk of releasing untested changes and wastes time on repetitive tasks. Additionally, Helm charts are only stored in the repository and not published to a chart repository, limiting external consumption and ArgoCD best practices.

## What Changes

### 1. OCI Image Versioning
- **Ensure release workflow tags images with semantic version** (e.g., `v1.0.70`) in addition to `sha-<commit>` and `latest`
- Verify `latest` tag is applied correctly during releases
- Update `docker/images/push_targets.bzl` and `container_tags.bzl` to support version-based tags

### 2. Helm Chart OCI Registry
- **Publish Helm charts to OCI registry** at `oci://ghcr.io/carverauto/charts/serviceradar`
- Add helm package/push step to release workflow
- Update `Chart.yaml` version and `appVersion` automatically during releases (via `cut-release.sh`)
- Configure ArgoCD to consume charts from OCI registry instead of raw Git paths

### 3. Demo-Staging Environment
- **Recreate `demo-staging` namespace** for pre-release validation
- Create ArgoCD Application for `demo-staging` (Helm-based, pointing to chart repo)
- Update `helm/serviceradar/values.yaml` to use `image.tag` with `APP_TAG` or `latest`
- Set `imagePullPolicy: Always` for mutable tags in staging

### 4. ArgoCD GitOps Promoter Integration
- **Integrate ArgoCD GitOps Promoter** (https://argo-gitops-promoter.readthedocs.io/en/latest/) for automated promotion
- Configure promotion flow: `demo-staging` -> `demo` -> release
- Add e2e test gate between staging and demo promotion
- Trigger release workflow only after successful demo deployment

### 5. Release Workflow Updates
- Modify `scripts/cut-release.sh` and `.github/workflows/release.yml` to:
  1. Build and push images with version tag
  2. Deploy to `demo-staging` via Helm/ArgoCD
  3. Run e2e tests
  4. Promote to `demo` using GitOps Promoter
  5. Only proceed with GitHub release after demo success

## Impact

- Affected specs: New `release-automation` capability
- Affected code:
  - `docker/images/push_targets.bzl`, `container_tags.bzl`
  - `.github/workflows/release.yml`
  - `scripts/cut-release.sh`
  - `helm/serviceradar/Chart.yaml`, `values.yaml`
  - `k8s/argocd/applications/` (new staging app)
  - New: GitHub Pages Helm repo configuration
  - New: GitOps Promoter configuration
