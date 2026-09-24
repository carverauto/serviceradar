## ADDED Requirements

### Requirement: Interface Config Check Results on Devices
The system SHALL record each interface config check verdict on the target device's metadata as a top-level `config_check_<check>` key holding the status and a `config_check_<check>_detail` key holding `checked_at`, `switch`, `interface`, `reason`, and `missing`, using the atomic metadata merge that never creates devices.
Status SHALL be one of `compliant`, `non_compliant`, or `unknown`. A verdict for a device UID that does not exist SHALL be skipped, and a result SHALL NOT write any metadata key outside `config_check_*`.

#### Scenario: Verdict is recorded
- **GIVEN** an existing device `sr:00000000-0000-4000-8000-000000000001`
- **WHEN** a config check result reports check `nac` as `non_compliant` with missing `authentication port-control auto`
- **THEN** the device metadata has `config_check_nac` = `non_compliant` and `config_check_nac_detail.missing` lists the pattern
- **AND** other metadata keys on the device are unchanged

#### Scenario: Verdict is queryable
- **GIVEN** devices with recorded `nac` verdicts
- **WHEN** an operator runs `in:devices metadata.config_check_nac:non_compliant`
- **THEN** only the non-compliant devices are returned

#### Scenario: Unknown device is not created
- **GIVEN** a config check result for a device UID that does not exist
- **WHEN** the result is ingested
- **THEN** no device is created
