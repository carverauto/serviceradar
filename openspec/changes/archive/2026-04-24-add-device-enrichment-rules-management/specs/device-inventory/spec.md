## ADDED Requirements
### Requirement: Rule-Driven Vendor and Type Enrichment
The system SHALL derive device `vendor_name`, `model`, `type`, and `type_id` through configurable enrichment rules that evaluate SNMP and mapper metadata.

#### Scenario: Ubiquiti router disambiguation using sysDescr/sysName
- **GIVEN** a device with ambiguous `sys_object_id` but `sys_descr` or `sys_name` indicating `UDM`
- **WHEN** enrichment rules are applied
- **THEN** `vendor_name` SHALL be set to `Ubiquiti`
- **AND** `type`/`type_id` SHALL be set to `Router`/`12`

#### Scenario: Ubiquiti switch disambiguation using sysName
- **GIVEN** a device with `sys_object_id` shared across platforms and `sys_name` containing `USW`
- **WHEN** enrichment rules are applied
- **THEN** `vendor_name` SHALL be set to `Ubiquiti`
- **AND** `type`/`type_id` SHALL be set to `Switch`/`10`

#### Scenario: Ubiquiti AP classification using sysDescr/sysName
- **GIVEN** a device with `sys_descr` or `sys_name` containing `U6` or `UAP`
- **WHEN** enrichment rules are applied
- **THEN** `vendor_name` SHALL be set to `Ubiquiti`
- **AND** `type` SHALL be set to an AP classification value

### Requirement: Classification Provenance Visibility in Inventory
The system SHALL store and expose enrichment provenance fields for each device classification decision.

#### Scenario: Provenance fields present after enrichment
- **WHEN** a rule classifies a device
- **THEN** `ocsf_devices.metadata` SHALL contain rule provenance fields
- **AND** API/UI reads of device inventory SHALL expose those provenance values

#### Scenario: Classification updated by higher-priority rule
- **GIVEN** an existing classified device
- **WHEN** a higher-priority matching rule is introduced and ingestion reprocesses the device
- **THEN** classification fields SHALL be updated to the new decision
- **AND** provenance SHALL reference the new winning rule
