## ADDED Requirements

### Requirement: Product release version agreement

Every ServiceRadar product release SHALL have one version identity across its
Git tag, `VERSION` file, Helm `Chart.yaml` `version` and `appVersion`, OCI Helm
chart tag, semantic OCI image tags, and Forgejo release. For product version
`X.Y.Z`, the Git tag SHALL be `vX.Y.Z` and the Helm chart tag SHALL be
`X.Y.Z`.

#### Scenario: A tagged product release has matching metadata

- **GIVEN** a release tag `vX.Y.Z` points at a commit reachable from `staging`
- **WHEN** the release workflow resolves that tag
- **THEN** it SHALL verify `VERSION`, Helm `version`, and Helm `appVersion`
  are all `X.Y.Z`
- **AND** it SHALL publish only product artifacts labeled for that same
  version

#### Scenario: Release metadata disagrees with the tag

- **GIVEN** a release tag `vX.Y.Z` points at a commit whose Helm or application
  version metadata is not `X.Y.Z`
- **WHEN** release publication is requested
- **THEN** the workflow SHALL fail before publishing an OCI chart, image, or
  Forgejo release

### Requirement: Release publication has a tagged source

The product release workflow SHALL publish artifacts only from an existing Git
tag reachable from `origin/staging`. A manual workflow dispatch SHALL select
or retry an existing tag and SHALL NOT treat an arbitrary branch head or
commit as a release source.

#### Scenario: Manual retry uses an existing release tag

- **GIVEN** an operator dispatches a retry for `vX.Y.Z`
- **AND** that tag exists and is reachable from `origin/staging`
- **WHEN** the workflow starts
- **THEN** it SHALL check out the tagged commit and validate its release
  metadata before publication

#### Scenario: Manual dispatch names a missing tag

- **GIVEN** an operator dispatches a release workflow with `vX.Y.Z`
- **AND** that Git tag does not exist
- **WHEN** the workflow starts
- **THEN** it SHALL fail before any build, signing, or artifact publication

### Requirement: Release version occupancy is fail-closed

The release path SHALL verify version occupancy before it changes release
metadata or publishes an OCI chart. It SHALL verify that neither the remote
Git tag nor the OCI Helm chart tag for the requested product version already
exists. A failed or unavailable verification SHALL abort the release.

#### Scenario: An OCI chart version is already occupied

- **GIVEN** the requested product version has no remote Git tag
- **AND** the OCI Helm repository already contains chart version `X.Y.Z`
- **WHEN** an operator runs the release cut helper
- **THEN** it SHALL refuse the cut before modifying `VERSION`, `CHANGELOG`, or
  Helm metadata
- **AND** it SHALL instruct the operator to select a new version

#### Scenario: Registry occupancy cannot be verified

- **GIVEN** an operator requests a product release
- **AND** the OCI Helm repository cannot be queried reliably
- **WHEN** the release cut helper or release workflow performs its preflight
- **THEN** it SHALL fail closed before artifact publication

### Requirement: Published product versions are immutable audit records

Once a product-version artifact exists in the OCI Helm repository, it SHALL
NOT be deleted, overwritten, or reused as a different product release. Legacy
chart-only artifacts SHALL be retained as historical audit records and the
next unoccupied product version SHALL be used.

#### Scenario: A legacy chart-only version blocks a later product release

- **GIVEN** an OCI Helm chart exists for `X.Y.Z` but no corresponding product
  Git tag or Forgejo release exists
- **WHEN** an operator attempts to cut product version `X.Y.Z`
- **THEN** the release path SHALL reject that version
- **AND** it SHALL not delete or republish the existing chart
- **AND** it SHALL require a later unoccupied product version

### Requirement: OCI chart publication authority is protected

Write credentials for the product OCI Helm repository SHALL be available only
to the protected release publication environment. Developer and ordinary CI
paths SHALL use read-only artifact checks and SHALL NOT directly publish a
chart version.

#### Scenario: A chart-only source change is ready to ship

- **GIVEN** a Helm configuration change is approved
- **WHEN** an operator needs to publish it
- **THEN** the change SHALL be included in a formally tagged product release
- **AND** the protected release workflow SHALL publish the matching chart
  version
