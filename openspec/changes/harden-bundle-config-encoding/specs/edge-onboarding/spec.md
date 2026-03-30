## ADDED Requirements

### Requirement: Bundle Config Encoding Must Be Injection-Safe
Edge and collector onboarding bundles MUST encode operator-controlled configuration values so they cannot inject additional YAML or TOML structure.

#### Scenario: Bootstrap YAML contains backslashes or quotes
- **WHEN** bundle generation includes a string value containing quotes, backslashes, or newlines
- **THEN** the generated YAML MUST encode that value as a single scalar
- **AND** the value MUST NOT create additional YAML keys or nodes

#### Scenario: OTel port override contains non-integer content
- **WHEN** an OTel collector package contains a non-integer or newline-bearing `server.port` override
- **THEN** bundle generation MUST reject or normalize that value to a safe integer scalar
- **AND** the generated TOML MUST NOT contain injected keys or tables
