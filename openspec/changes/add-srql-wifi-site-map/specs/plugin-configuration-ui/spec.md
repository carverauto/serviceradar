## ADDED Requirements

### Requirement: Customer plugin source management UI

The Settings UI SHALL allow authorized operators to manage customer-owned plugin Git sources, including credentials, trust policy, sync controls, and source health.

#### Scenario: Operator adds a customer plugin repository
- **GIVEN** an authorized operator opens plugin source settings
- **WHEN** they enter a repository URL, ref, manifest path, auth method, credential reference, and signing trust policy
- **THEN** the UI SHALL validate required fields before save
- **AND** it SHALL NOT echo raw credential values after save
- **AND** it SHALL show the source as disabled or unsynced until a successful sync occurs

#### Scenario: Operator tests and syncs a customer source
- **GIVEN** a customer plugin source is configured
- **WHEN** an authorized operator clicks test or sync
- **THEN** the UI SHALL show reachability, authentication, manifest validation, verification, and import status
- **AND** failures SHALL include actionable diagnostics without exposing secret values

### Requirement: Customer plugin catalog provenance

The plugin package UI SHALL present customer-sourced plugins alongside supported plugins while clearly showing provenance, verification state, and staged review status.

#### Scenario: Customer plugin appears in plugin catalog
- **GIVEN** a customer plugin source sync has discovered a verified plugin version
- **WHEN** an authorized operator opens the plugin package UI
- **THEN** the UI SHALL show the plugin source name, repository provenance, source ref, package digest, signing identity, verification timestamp, and review status
- **AND** the plugin SHALL be visually distinct from ServiceRadar-supported plugins

#### Scenario: Operator imports a verified customer plugin
- **GIVEN** a discovered customer plugin version has passed source verification but has not been staged
- **WHEN** an operator with plugin staging permission imports it
- **THEN** the package SHALL enter the existing staged review workflow
- **AND** the review UI SHALL show requested capabilities, approved capabilities, allowlists, seed-file permissions, config schema, and source provenance

### Requirement: Customer plugin assignment configuration

The plugin assignment UI SHALL support customer plugin configuration schemas and seed-file permission review before assignment.

#### Scenario: Operator configures CSV seed mode
- **GIVEN** a customer WiFi-map plugin exposes a config schema for `csv_seed` mode
- **WHEN** an operator creates an assignment
- **THEN** the UI SHALL render fields for seed CSV inputs and plugin-specific options
- **AND** it SHALL require explicit approval for any host file roots or object references used by seed data
- **AND** saved assignment configuration SHALL reference secrets and file roots without exposing raw secret values
