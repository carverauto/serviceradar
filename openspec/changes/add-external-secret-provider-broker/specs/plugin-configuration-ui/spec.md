## ADDED Requirements

### Requirement: Plugin secret fields can select external references
Plugin secret-reference fields SHALL allow selecting compatible external secret references from unified credential management in addition to internally encrypted credentials.

#### Scenario: Select external HTTP token for plugin
- **GIVEN** a plugin descriptor or config schema requires an HTTP API token
- **AND** a compatible external reference exists
- **WHEN** an admin configures the plugin or monitoring binding
- **THEN** the UI SHALL allow selecting that external reference
- **AND** runtime configuration SHALL receive only a broker grant/reference, not the resolved token

### Requirement: Plugin configuration warns when direct credential exposure is requested
The plugin configuration UI SHALL reject or warn on schemas that attempt to pass raw credential fields directly to plugin params when a brokered secret-reference field is required.

#### Scenario: Plugin schema contains password text field
- **GIVEN** a plugin config schema asks for a plain password field
- **WHEN** the package is imported or configured
- **THEN** the UI/import review SHALL flag the field as unsafe for credential material
- **AND** administrators SHALL be directed to use a secret-reference/brokered credential field

