# Change: Add Release Staging Pipeline with Promotion Gates

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

### 4. Environment Promotion (Manual, PR-Based)
- Promote from `demo-staging` -> `demo` by updating the `demo` ArgoCD Application to pin:
  - chart version (`targetRevision`)
  - image tag (`global.imageTag`)
- Use e2e test results against `demo-staging` as the gate for promotion
- Future enhancement: automatically open a promotion PR when staging e2e tests pass

### 5. Release Workflow Updates
- Modify `scripts/cut-release.sh` and `.github/workflows/release.yml` to:
  1. Build and push images with version tag
  2. Publish Helm chart to GHCR OCI
  3. Deploy/update `demo-staging` via ArgoCD (Helm chart tracking latest)
  4. Run e2e tests against `demo-staging` and record commit status
  5. Promote to `demo` via PR when staging is healthy

## Impact

- Affected specs: New `release-automation` capability
- Affected code:
  - `docker/images/push_targets.bzl`, `container_tags.bzl`
  - `.github/workflows/release.yml`
  - `.github/workflows/e2e-tests.yml`
  - `scripts/cut-release.sh`
  - `helm/serviceradar/Chart.yaml`, `values.yaml`
  - `k8s/argocd/applications/` (new staging app)
  - `k8s/argocd/applications/demo-prod.yaml` (demo pinned to a version)
