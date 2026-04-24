## MODIFIED Requirements

### Requirement: Release import and mirroring use constrained outbound fetches
The platform SHALL constrain release-import and artifact-mirroring outbound HTTP fetches to approved HTTPS destinations and SHALL reject requests to private, loopback, link-local, or otherwise disallowed hosts.

Repository-backed agent release import SHALL use Forgejo on `code.carverauto.dev` as the only supported repository release source. The release-management UI SHALL default repository imports to `https://code.carverauto.dev/carverauto/serviceradar`. Core-side artifact mirroring SHALL only download signed manifest artifact URLs that satisfy the same outbound destination policy.

#### Scenario: Release import defaults to the Forgejo repository
- **GIVEN** an operator opens the agent releases settings page
- **WHEN** the repository release import form is rendered
- **THEN** the repository source defaults to `https://code.carverauto.dev/carverauto/serviceradar`
- **AND** recent repository release discovery targets Forgejo on `code.carverauto.dev`

#### Scenario: Importer rejects GitHub as a repository release source
- **GIVEN** an operator or API client submits `https://github.com/carverauto/serviceradar` as the repository source for agent release import
- **WHEN** the importer validates the repository source
- **THEN** the import is rejected before any outbound request is made
- **AND** no provider credentials are sent to GitHub hosts

#### Scenario: Artifact mirroring rejects disallowed host
- **GIVEN** a signed release manifest references an artifact URL on a disallowed host
- **WHEN** core attempts to mirror the artifact
- **THEN** mirroring fails closed
- **AND** the release is not marked as mirrored
