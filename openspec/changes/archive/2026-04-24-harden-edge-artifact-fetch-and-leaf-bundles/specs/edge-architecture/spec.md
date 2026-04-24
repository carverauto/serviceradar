## ADDED Requirements

### Requirement: Release artifact mirroring validates every fetch hop
The platform SHALL mirror release artifacts only from outbound destinations that satisfy the release fetch policy on every HTTP hop, including redirects. Mirroring SHALL reject redirects that resolve to disallowed, private, loopback, link-local, or non-HTTPS destinations.

#### Scenario: Redirect target is revalidated before mirroring continues
- **GIVEN** a signed release manifest references an HTTPS artifact URL on an allowed public host
- **AND** that host responds with a redirect
- **WHEN** core mirrors the artifact
- **THEN** the redirect target is normalized and revalidated through the release fetch policy before any follow-up request
- **AND** mirroring fails closed if the redirect target is disallowed

#### Scenario: URL without a path still mirrors safely
- **GIVEN** a valid artifact URL whose parsed path is empty
- **WHEN** core derives the mirrored object name
- **THEN** it uses a safe fallback basename
- **AND** mirroring does not crash on path extraction

### Requirement: Release artifact mirroring enforces bounded downloads
The platform SHALL enforce the mirrored artifact byte limit while streaming the download, and SHALL abort the fetch as soon as the artifact exceeds the configured limit instead of buffering the full response in memory.

#### Scenario: Oversize artifact is rejected during streaming
- **GIVEN** a mirrored artifact response exceeds the configured maximum mirror size
- **WHEN** core streams the artifact download
- **THEN** the transfer is aborted once the limit is exceeded
- **AND** the artifact is not uploaded into internal storage

### Requirement: Edge-site setup bundles treat site metadata as data
Generated edge-site NATS leaf setup artifacts SHALL shell-escape edge-site names and other interpolated site metadata before embedding them into operator-run shell content.

#### Scenario: Edge-site name containing shell metacharacters does not execute
- **GIVEN** an edge site name contains shell metacharacters such as `$()`, backticks, or quotes
- **WHEN** the platform generates the NATS leaf setup script or related shell-facing bundle content
- **THEN** the resulting script treats the site name as literal text
- **AND** no command substitution or injected shell syntax is introduced
