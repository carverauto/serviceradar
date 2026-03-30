## MODIFIED Requirements

### Requirement: Signed agent release catalog
The system SHALL maintain a catalog of publishable agent releases. Each release entry SHALL include signed manifest metadata for every supported platform/package artifact, including version, artifact URL, SHA256 digest, supported platform metadata, and publication timestamp. Operators SHALL be able to publish release metadata either manually or by importing signed manifest assets from a repository-hosted release. The control plane SHALL reject incomplete or unsigned release metadata for rollout use.

Repository release import SHALL be restricted to trusted hosts only:
- GitHub imports SHALL use `https://github.com/<owner>/<repo>` with GitHub-owned API and asset hosts.
- Forgejo imports SHALL use `https://code.carverauto.dev/<owner>/<repo>` with the matching Forgejo API on `code.carverauto.dev`.

The importer SHALL apply a fail-closed outbound URL policy to all release metadata and asset fetches, SHALL require HTTPS, SHALL reject private/loopback/link-local destinations, and SHALL NOT forward provider auth credentials to untrusted asset hosts.

#### Scenario: Import a signed repository release
- **GIVEN** a repository-hosted release exposes a signed manifest asset and matching signature asset for version `v1.2.3`
- **WHEN** an operator imports that release from the release-management UI
- **THEN** the control plane fetches the manifest assets only from trusted provider hosts
- **AND** validates the signature
- **AND** stores the release as eligible for rollout targeting
- **AND** the imported release retains source metadata identifying the repository release it came from

#### Scenario: Reject untrusted Forgejo host
- **GIVEN** an operator enters a Forgejo repository URL on any host other than `code.carverauto.dev`
- **WHEN** the importer validates the repository source
- **THEN** the import is rejected before any outbound request is made

#### Scenario: Reject asset redirect to untrusted host
- **GIVEN** the provider API returns an asset download URL on a non-provider host
- **WHEN** the importer attempts to fetch the asset
- **THEN** the importer rejects the download
- **AND** provider auth headers are not sent to that host
