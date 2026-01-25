## ADDED Requirements
### Requirement: Plugin Bundle Upload
The system SHALL accept a plugin bundle (`.zip`) that contains `plugin.yaml` and `plugin.wasm`, and it SHALL use the bundle as a single upload artifact for plugin imports.

#### Scenario: Valid bundle upload
- **GIVEN** a bundle containing `plugin.yaml` and `plugin.wasm`
- **WHEN** the bundle is uploaded
- **THEN** the system validates the manifest and Wasm blob
- **AND** the package enters the staged approval flow

#### Scenario: Missing required file
- **GIVEN** a bundle missing `plugin.yaml` or `plugin.wasm`
- **WHEN** the bundle is uploaded
- **THEN** the system rejects the upload
- **AND** returns a validation error that lists the missing file

### Requirement: Bundle Sidecar Files
The system SHALL accept optional sidecar files in the bundle (`config.schema.json`, `display_contract.json`) and SHALL apply them during import.

#### Scenario: Sidecar schema and display contract
- **GIVEN** a bundle that includes `config.schema.json` and `display_contract.json`
- **WHEN** the bundle is uploaded
- **THEN** the system validates the JSON files
- **AND** stores them alongside the plugin package

### Requirement: Sidecar Precedence
The system SHALL prefer sidecar files over manifest-embedded fields when both are present.

#### Scenario: Display contract override
- **GIVEN** a manifest containing `display_contract` and a bundle containing `display_contract.json`
- **WHEN** the bundle is uploaded
- **THEN** the system uses `display_contract.json` as the display contract

#### Scenario: Config schema override
- **GIVEN** a bundle containing `config.schema.json`
- **WHEN** the bundle is uploaded
- **THEN** the system uses that schema for assignment validation

### Requirement: Bundle Safety
The system MUST reject bundle entries with path traversal or unexpected filenames.

#### Scenario: Path traversal rejected
- **GIVEN** a bundle containing `../plugin.wasm`
- **WHEN** the bundle is uploaded
- **THEN** the system rejects the bundle with a security error

### Requirement: Example Bundle Artifact
The repository SHALL include an example plugin bundle artifact layout to guide developers.

#### Scenario: Harness bundle build
- **GIVEN** the wasm plugin harness
- **WHEN** the build script runs
- **THEN** it produces a bundle zip containing the manifest, Wasm blob, and optional sidecar files
