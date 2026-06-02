## ADDED Requirements

### Requirement: Endpoint Inventory Configuration
The `serviceradar-agent` SHALL support endpoint inventory configuration through the same effective configuration resolution path used for managed agent collectors.

#### Scenario: Remote profile enables endpoint inventory
- **GIVEN** an agent has no local endpoint inventory override
- **AND** the control plane assigns a profile with endpoint inventory enabled
- **WHEN** the agent resolves its effective configuration
- **THEN** the agent SHALL schedule endpoint inventory collection according to the profile cadence
- **AND** it SHALL apply the profile source, redaction, and size-limit settings

#### Scenario: Local endpoint inventory override
- **GIVEN** an agent has a local endpoint inventory configuration file
- **WHEN** the agent resolves endpoint inventory configuration
- **THEN** the local configuration SHALL take precedence over the remote profile
- **AND** the agent SHALL log that a local endpoint inventory override is active

#### Scenario: Invalid endpoint inventory configuration
- **GIVEN** an endpoint inventory configuration contains an invalid cadence, unsupported source, or unsafe limit
- **WHEN** the agent validates configuration
- **THEN** the endpoint inventory collector SHALL remain disabled
- **AND** the agent SHALL report a bounded configuration error in status

### Requirement: Endpoint Inventory Spool Validation
The agent SHALL validate local endpoint inventory spool artifacts before upload.

#### Scenario: Valid spool artifact uploaded
- **GIVEN** the endpoint inventory collector writes a valid bounded CycloneDX JSON artifact to the configured spool location
- **WHEN** the agent reads the spool artifact
- **THEN** the agent SHALL validate format, size, scan metadata, and digest
- **AND** it SHALL upload the artifact and normalized summary through the configured control-plane path only when the package-set or artifact hash changed or policy forces refresh

#### Scenario: Invalid spool artifact rejected
- **GIVEN** the endpoint inventory collector writes malformed JSON or a mismatched digest
- **WHEN** the agent reads the spool artifact
- **THEN** the agent SHALL reject the artifact
- **AND** it SHALL keep the previous successful endpoint inventory state

### Requirement: Endpoint Inventory Local Cache
The agent SHALL persist a local last-known-good endpoint inventory cache that can serve unchanged scan decisions and on-demand query commands.

#### Scenario: Cache updated after successful scan
- **GIVEN** endpoint inventory collection succeeds
- **WHEN** the agent validates the collector output
- **THEN** it SHALL persist normalized package identities, package-set hash, artifact hash, source summaries, scan timestamp, collector version, and redaction policy in the local cache
- **AND** it SHALL record whether the package-set hash has been uploaded successfully

#### Scenario: Control plane unavailable during changed scan
- **GIVEN** endpoint inventory collection succeeds with a changed package-set hash
- **AND** the control plane upload path is unavailable
- **WHEN** the agent handles the scan result
- **THEN** it SHALL keep the changed inventory in the local cache
- **AND** it SHALL retry upload according to bounded retry policy without losing the previous uploaded hash metadata

#### Scenario: Cache answers on-demand query
- **GIVEN** an agent has a valid local endpoint inventory cache
- **WHEN** it receives an endpoint inventory query command over the control stream
- **THEN** it SHALL evaluate supported predicates against the local cache
- **AND** it SHALL return compact results without requiring a package manager rescan unless the command requests and is authorized for a fresh scan

### Requirement: Endpoint Inventory On-Demand Command Policy
The agent SHALL enforce endpoint inventory policy and command bounds before running live inventory commands.

#### Scenario: Unsupported predicate rejected
- **GIVEN** an endpoint inventory query command contains an unsupported predicate or unsafe limit
- **WHEN** the agent validates the command
- **THEN** it SHALL reject the command with a bounded error
- **AND** it SHALL NOT run a fresh scan or upload an artifact

#### Scenario: Disabled source cannot be queried freshly
- **GIVEN** endpoint inventory policy enables OS packages only
- **WHEN** an on-demand command requests a fresh language-manifest scan
- **THEN** the agent SHALL reject the fresh source request
- **AND** it SHALL NOT collect the disabled source
