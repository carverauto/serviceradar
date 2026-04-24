## ADDED Requirements
### Requirement: Vendor-Scoped Enrichment Rule Matching
The system SHALL only apply vendor-specific device enrichment rules when the input payload contains evidence that is scoped to that vendor.

#### Scenario: Aruba switch does not match Ubiquiti rule
- **GIVEN** a device payload with Aruba fingerprint signals and no Ubiquiti-specific evidence
- **WHEN** enrichment rules are evaluated
- **THEN** Ubiquiti-specific rules SHALL NOT match
- **AND** the resulting classification SHALL NOT set `vendor_name` to `Ubiquiti`

#### Scenario: Ubiquiti classification still works with explicit evidence
- **GIVEN** a device payload that includes Ubiquiti-specific evidence required by a Ubiquiti rule
- **WHEN** enrichment rules are evaluated
- **THEN** the matching Ubiquiti rule SHALL classify the device with `vendor_name=Ubiquiti`
- **AND** vendor/type output SHALL remain consistent with existing Ubiquiti router/switch/AP expectations

### Requirement: Aruba Switch Classification Guardrail
The system SHALL classify Aruba switch fingerprints as Aruba switch devices when Aruba-specific evidence is present and no higher-priority vendor-specific rule applies.

#### Scenario: Aruba switch fingerprint classification
- **GIVEN** a device payload with Aruba switch fingerprint signals
- **WHEN** enrichment rules are evaluated
- **THEN** the winning rule SHALL set `vendor_name=Aruba`
- **AND** the winning rule SHALL set `type=Switch` and `type_id=10`
