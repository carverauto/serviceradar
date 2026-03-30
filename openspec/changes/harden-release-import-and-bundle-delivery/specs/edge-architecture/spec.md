## ADDED Requirements

### Requirement: Release import and mirroring use constrained outbound fetches
The platform SHALL constrain release-import and artifact-mirroring outbound HTTP fetches to approved HTTPS destinations and SHALL reject requests to private, loopback, link-local, or otherwise disallowed hosts.

GitHub release import SHALL be limited to GitHub-owned repository, API, and release-asset hosts. Forgejo release import SHALL be limited to `code.carverauto.dev`. Core-side artifact mirroring SHALL only download signed manifest artifact URLs that satisfy the same outbound destination policy.

#### Scenario: Importer rejects private or loopback destination
- **GIVEN** a release import source or asset URL resolves to a private or loopback address
- **WHEN** the importer validates the outbound request
- **THEN** the request is rejected
- **AND** no credentials are sent

#### Scenario: Artifact mirroring rejects disallowed host
- **GIVEN** a signed release manifest references an artifact URL on a disallowed host
- **WHEN** core attempts to mirror the artifact
- **THEN** mirroring fails closed
- **AND** the release is not marked as mirrored
