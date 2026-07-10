## ADDED Requirements
### Requirement: Integration Source Settings Propagation
The sync configuration generator SHALL include non-secret integration source settings in agent sync payloads so source drivers can consume per-source behavior controls.

#### Scenario: Armis field settings reach the sync agent
- **GIVEN** an Armis integration source has settings containing `extra_metadata_fields`
- **WHEN** the control plane generates sync configuration for the assigned agent
- **THEN** the emitted source payload SHALL include a `settings` object containing `extra_metadata_fields`
- **AND** the payload SHALL continue to include credentials only in the `credentials` object

#### Scenario: Armis asset field settings reach the sync agent
- **GIVEN** an Armis integration source has settings containing `asset_fields`
- **WHEN** the control plane generates sync configuration for the assigned agent
- **THEN** the emitted source payload SHALL include the configured `asset_fields`
- **AND** the Armis sync driver SHALL be able to use those fields for asset enrichment

#### Scenario: Armis v3 credentials can be stored for asset enrichment
- **GIVEN** an operator edits an Armis integration source
- **WHEN** the operator provides Armis v3 OAuth client ID, client secret, and vendor ID values
- **THEN** the credentials SHALL be stored in the integration source credentials object
- **AND** existing v1 API key and API secret credentials SHALL remain supported during migration

#### Scenario: Empty source settings are omitted
- **GIVEN** an integration source has no source settings
- **WHEN** the control plane generates sync configuration
- **THEN** the emitted source payload SHALL omit `settings`
