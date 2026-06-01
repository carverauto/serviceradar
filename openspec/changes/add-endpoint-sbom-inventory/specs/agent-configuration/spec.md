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
- **AND** it SHALL upload the artifact and normalized summary through the configured control-plane path

#### Scenario: Invalid spool artifact rejected
- **GIVEN** the endpoint inventory collector writes malformed JSON or a mismatched digest
- **WHEN** the agent reads the spool artifact
- **THEN** the agent SHALL reject the artifact
- **AND** it SHALL keep the previous successful endpoint inventory state
