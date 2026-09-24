## ADDED Requirements

### Requirement: Interface Config Check Results on Devices
The system SHALL record interface config check verdicts on the target device's metadata under `config_check.<check name>` with `status`, `checked_at`, `switch`, `interface`, and `missing`, using an atomic merge that never creates devices.
Status SHALL be one of `compliant`, `non_compliant`, or `unknown`; an `unknown` verdict SHALL include a `reason`. A result for a device UID that does not exist SHALL be skipped and counted, not created.

#### Scenario: Verdict is recorded
- **GIVEN** an existing device `sr:00000000-0000-4000-8000-000000000001`
- **WHEN** a config check result reports check `nac` as `non_compliant` with missing `authentication port-control auto`
- **THEN** the device metadata contains `config_check.nac.status` = `non_compliant` and the missing pattern
- **AND** other metadata keys on the device are unchanged

#### Scenario: Verdict is queryable
- **GIVEN** devices with recorded `nac` verdicts
- **WHEN** an operator runs `in:devices metadata.config_check.nac.status:non_compliant`
- **THEN** only the non-compliant devices are returned

#### Scenario: Unknown device is not created
- **GIVEN** a config check result for a device UID that does not exist
- **WHEN** the result is ingested
- **THEN** no device is created and the result counts the skipped UID
