## ADDED Requirements

### Requirement: Plugin secret references reuse unified credential inventory
Plugin configuration UI SHALL allow secret-reference fields to select compatible credentials from the unified credential inventory and create new compatible secrets inline when supported.

#### Scenario: Select plugin credential
- **GIVEN** a plugin schema declares a secret reference field
- **WHEN** the admin configures the plugin
- **THEN** the UI SHALL offer compatible existing credentials from the unified inventory
- **AND** it SHALL pass only secret references or broker grants to runtime configuration

#### Scenario: Create plugin credential inline
- **GIVEN** a plugin secret reference field maps to a known provider/auth preset
- **WHEN** the admin enters new secret material inline
- **THEN** the system SHALL create an encrypted credential secret
- **AND** the plugin configuration SHALL reference that secret rather than storing plaintext
