## ADDED Requirements

### Requirement: ScaLibr Skip Directory Configuration
The add-on assignment and profile configuration UI SHALL let operators edit `dirs_to_skip` for `scalibr-endpoint-inventory` as a list of absolute directory paths.

#### Scenario: Operator adds a host-specific skip directory
- **GIVEN** an operator is editing a `scalibr-endpoint-inventory` assignment or profile
- **WHEN** they add an absolute directory path to `dirs_to_skip` and save
- **THEN** the stored add-on parameters SHALL include that path
- **AND** the next delivered config for targeted agents SHALL carry it in `dirs_to_skip`

#### Scenario: Skip directory field is explained
- **GIVEN** the `scalibr-endpoint-inventory` config schema
- **WHEN** the configuration form renders `dirs_to_skip`
- **THEN** the field SHALL be visible (not hidden)
- **AND** its description SHALL state that listed directories and their descendants are skipped during the filesystem walk
