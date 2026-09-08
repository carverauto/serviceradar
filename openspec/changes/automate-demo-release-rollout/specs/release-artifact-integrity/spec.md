## ADDED Requirements

### Requirement: Verified releases roll to demo automatically

The release system SHALL automatically reconcile the `demo` environment after a
non-prerelease product release and its complete required artifact set have been
verified and finalized. Automatic reconciliation SHALL follow only the guarded
`demo/prod-release` source revision and SHALL NOT enable pruning, empty-application
synchronization, or continuous self-healing.

#### Scenario: Complete release reaches demo without operator action

- **GIVEN** a tagged non-prerelease product release has matching metadata
- **AND** its images, Helm chart, packages, catalogs, signatures, and security assets verify
- **WHEN** the release finalizer publishes the release and advances `demo/prod-release`
- **THEN** ArgoCD SHALL automatically synchronize the new guarded revision
- **AND** the ServiceRadar workloads SHALL use the release's semantic image tag
- **AND** no operator sync command SHALL be required

#### Scenario: Incomplete release does not deploy

- **GIVEN** release publication, parallel asset verification, or finalization fails
- **WHEN** the release workflow reaches its promotion stage
- **THEN** it SHALL NOT advance `demo/prod-release`
- **AND** ArgoCD SHALL retain the previously verified demo revision

#### Scenario: Automatic reconciliation is non-destructive

- **GIVEN** a verified release revision removes a resource or unrelated live drift exists
- **WHEN** ArgoCD automatically synchronizes the release
- **THEN** it SHALL NOT prune the absent resource
- **AND** it SHALL NOT continuously self-heal unrelated live drift
- **AND** an explicit operator action SHALL remain required for deletion or drift correction
