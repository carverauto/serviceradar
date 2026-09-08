## ADDED Requirements

### Requirement: Plugin Repository Registry
The system MUST persist plugin repositories as records rather than configuration, and every plugin
import MUST resolve its source from a stored repository record.

#### Scenario: Repository selection persists across sessions
- **GIVEN** an administrator has added a plugin repository
- **WHEN** the administrator leaves and returns to the plugins settings page
- **THEN** the repository is still listed and selectable
- **AND** the selection is not lost when the LiveView remounts

#### Scenario: Built-in repository is seeded and immutable
- **GIVEN** a deployment upgraded to include the plugin repository registry
- **WHEN** the migration runs
- **THEN** the first-party `carverauto/serviceradar` repository exists as a record marked built-in
- **AND** it is the default selection
- **AND** attempts to edit or delete it are rejected
- **AND** it MAY be disabled

#### Scenario: Recurring sync covers every enabled repository
- **GIVEN** two enabled repositories, the built-in one and a third-party one
- **WHEN** the recurring first-party sync worker runs
- **THEN** it imports eligible packages from both repositories
- **AND** a failure fetching one repository does not prevent the other from importing

#### Scenario: Disabled repository is not imported from
- **GIVEN** a repository that has been disabled
- **WHEN** the recurring sync worker runs
- **THEN** no packages are imported from that repository
- **AND** packages previously imported from it remain in their existing approval state

### Requirement: Per-Repository Signature Verification
The system MUST verify each imported plugin bundle's ed25519 upload signature against the trusted
signing key of the repository it was imported from, and MUST reject imports that do not verify.

#### Scenario: Third-party bundle verifies against its own repository key
- **GIVEN** a repository configured with signing key id `acme-v1` and its public key
- **AND** a bundle in that repository signed with the matching private key
- **WHEN** the bundle is imported
- **THEN** the signature verifies
- **AND** the package is staged for review

#### Scenario: Bundle signed by another repository's key is rejected
- **GIVEN** repositories A and B with different signing keys
- **AND** a bundle signed with repository A's key published in repository B
- **WHEN** the bundle is imported through repository B
- **THEN** the import is rejected with a signature verification error
- **AND** no package is staged

#### Scenario: Repository without a signing key cannot be created
- **GIVEN** an administrator adding a repository
- **WHEN** the signing key id or public key is omitted
- **THEN** the repository is not created
- **AND** the form reports which field is missing

#### Scenario: First-party OCI artifacts keep cosign verification
- **GIVEN** an index entry from the built-in repository that references an OCI artifact
- **WHEN** the artifact is imported
- **THEN** cosign verification against the first-party key is still performed
- **AND** the OCI registry allowlist is still enforced

### Requirement: Private Repository Credentials
The system MUST support importing plugins from private GitHub repositories using a per-repository
credential, stored encrypted at rest, and MUST NOT disclose that credential to hosts other than the
GitHub API.

#### Scenario: Private repository import succeeds with an attached credential
- **GIVEN** a repository marked private with an attached GitHub personal access token credential
- **WHEN** the plugin index and bundle assets are fetched
- **THEN** the requests authenticate as that token
- **AND** the release assets download successfully

#### Scenario: Credential is not forwarded across an asset redirect
- **GIVEN** a private repository asset download that redirects to a pre-signed asset host
- **WHEN** the redirect is followed
- **THEN** the request to the pre-signed host carries no Authorization header

#### Scenario: Credential is never exposed in reads or audit records
- **GIVEN** a repository with an attached credential
- **WHEN** the repository is read through the API, the UI, or an audit record
- **THEN** the response indicates only that a credential is attached
- **AND** the token value is not present

#### Scenario: Private repository without a credential fails clearly
- **GIVEN** a repository whose GitHub repository is private and which has no credential attached
- **WHEN** an import is attempted
- **THEN** the import fails with an error identifying the missing credential
- **AND** the error does not present the failure as a missing or empty release

### Requirement: Plugin Repository Authorization and Audit
The system MUST gate plugin repository management behind a dedicated permission that is not implied
by the permission to stage packages, and MUST record an audit event for every repository change.

#### Scenario: Staging permission alone cannot add a repository
- **GIVEN** a user holding `plugins.stage` but not `plugins.repositories.manage`
- **WHEN** the user attempts to add a repository
- **THEN** the attempt is rejected
- **AND** no repository is created

#### Scenario: Authorization is enforced outside the UI
- **GIVEN** a caller without `plugins.repositories.manage`
- **WHEN** a repository create, update, or destroy is attempted directly against the resource
- **THEN** the action is refused by policy

#### Scenario: Repository changes are audited
- **GIVEN** an administrator with `plugins.repositories.manage`
- **WHEN** the administrator adds, edits, enables, disables, or removes a repository
- **THEN** an audit record is written identifying the actor, the action, the repository URL, and the
  signing key id
- **AND** the record contains no credential material
