## ADDED Requirements

### Requirement: OCI Image Version Tagging
The release workflow SHALL tag all OCI images with the semantic version (e.g., `v1.0.70`) in addition to `sha-<commit>` and `latest` tags.

#### Scenario: Release triggers version-tagged image push
- **WHEN** a release tag `v1.0.70` is pushed to the repository
- **THEN** all images in `GHCR_PUSH_TARGETS` SHALL be pushed with tags:
  - `v1.0.70` (semantic version)
  - `sha-<commit>` (immutable digest-based)
  - `latest` (mutable latest reference)

#### Scenario: Version tag matches VERSION file
- **WHEN** the release workflow runs
- **THEN** the image version tag SHALL match the content of the VERSION file

### Requirement: Helm Chart OCI Registry
The project SHALL publish Helm charts to the OCI registry at `oci://ghcr.io/carverauto/charts/serviceradar`.

#### Scenario: Chart published on release
- **WHEN** a new release is created
- **THEN** the `serviceradar` Helm chart SHALL be packaged and pushed to `oci://ghcr.io/carverauto/charts`
- **AND** the chart SHALL be tagged with the release version (e.g., `1.0.70`)

#### Scenario: Chart version synchronization
- **WHEN** `cut-release.sh` is executed with a version
- **THEN** the `Chart.yaml` version SHALL be updated to match the release version
- **AND** the `appVersion` SHALL reflect the application release version
- **AND** the Chart.yaml changes SHALL be included in the release commit

#### Scenario: Chart accessibility
- **WHEN** a user runs `helm show chart oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.70`
- **THEN** the chart metadata SHALL be displayed
- **AND** the chart SHALL be pullable for installation

### Requirement: Demo-Staging Environment
The project SHALL maintain a persistent `demo-staging` environment for pre-release validation deployed via ArgoCD and Helm. This is the first environment where new releases are tested before promotion to demo.

#### Scenario: Staging deployment from chart repository
- **WHEN** a new chart version is published
- **THEN** ArgoCD SHALL automatically sync the `demo-staging` application
- **AND** the deployment SHALL use `imagePullPolicy: Always` for mutable tags

#### Scenario: Staging isolation
- **WHEN** demo-staging is deployed
- **THEN** it SHALL use the `demo-staging` Kubernetes namespace
- **AND** it SHALL have isolated ingress (e.g., `staging.serviceradar.cloud`)

### Requirement: GitOps Promotion Pipeline
The release process SHALL use ArgoCD GitOps Promoter to automate environment promotion from `demo-staging` to `demo`.

#### Scenario: Automatic promotion on test success
- **WHEN** e2e tests pass against `demo-staging`
- **THEN** the GitOps Promoter SHALL automatically promote to `demo` environment
- **AND** a commit status update SHALL be recorded

#### Scenario: Promotion gate failure
- **WHEN** e2e tests fail against `demo-staging`
- **THEN** promotion to `demo` SHALL be blocked
- **AND** an alert SHALL be generated for manual investigation

#### Scenario: Manual promotion override
- **WHEN** an operator needs to bypass automated promotion
- **THEN** manual promotion SHALL be possible via GitOps Promoter CLI or UI
- **AND** the override SHALL be logged for audit purposes

### Requirement: E2E Test Credentials via GitHub Environments
E2E tests SHALL authenticate using application-level credentials stored in GitHub Environments, not cluster credentials.

#### Scenario: Staging environment secrets
- **WHEN** e2e tests run against `demo-staging`
- **THEN** the workflow SHALL use the `demo-staging` GitHub Environment
- **AND** credentials SHALL be retrieved from `SERVICERADAR_ADMIN_PASSWORD` and `SERVICERADAR_CORE_URL` secrets

#### Scenario: Demo environment secrets
- **WHEN** e2e tests run against `demo`
- **THEN** the workflow SHALL use the `demo` GitHub Environment
- **AND** credentials SHALL be retrieved from environment-specific secrets

#### Scenario: No cluster credentials in CI
- **WHEN** e2e tests execute
- **THEN** tests SHALL authenticate via HTTP API using admin credentials
- **AND** kubectl/kubeadm credentials SHALL NOT be exposed to GitHub Actions

### Requirement: Staged Release Workflow
The release workflow SHALL deploy to staging and validate before creating the GitHub release.

#### Scenario: Pre-release staging deployment
- **WHEN** `scripts/cut-release.sh --version X.Y.Z --push` is executed
- **THEN** images SHALL be built and pushed with version tag
- **AND** the `demo-staging` environment SHALL be updated
- **AND** e2e tests SHALL run against staging
- **AND** only after staging success SHALL the GitHub release be created

#### Scenario: Hotfix bypass
- **WHEN** `scripts/cut-release.sh --version X.Y.Z --skip-staging` is executed
- **THEN** the staging deployment and promotion steps SHALL be skipped
- **AND** the release SHALL proceed directly to GitHub release creation

### Requirement: ArgoCD Application Configuration
ArgoCD applications for demo environments SHALL use Helm charts from the OCI registry.

#### Scenario: Demo application Helm source
- **WHEN** the `demo` ArgoCD Application is deployed
- **THEN** it SHALL reference `ghcr.io/carverauto/charts` as the Helm source
- **AND** it SHALL use a specific version tag (not `*`) for production stability

#### Scenario: Staging application Helm source
- **WHEN** the `demo-staging` ArgoCD Application is deployed
- **THEN** it SHALL reference `ghcr.io/carverauto/charts` as the Helm source
- **AND** it MAY use `*` (latest) chart version for continuous testing
