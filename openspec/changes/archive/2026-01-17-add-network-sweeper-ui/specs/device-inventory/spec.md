# device-inventory Specification

## Purpose

Extend device inventory with user-defined tags to support bulk edits and sweep group targeting.

## ADDED Requirements

### Requirement: Device Tags Map

The system SHALL store user-defined device tags in `ocsf_devices.tags` as a JSONB map of key/value pairs.

#### Scenario: Persist tag keys and values
- **GIVEN** a user applies tags `env=prod` and `critical` to a device
- **WHEN** the device record is saved
- **THEN** `ocsf_devices.tags` SHALL include `env` with value `"prod"`
- **AND** tags without values SHALL be stored with an empty string value

---

### Requirement: Bulk Tag Application

The system SHALL allow users to apply tags to multiple devices via bulk edit.

#### Scenario: Bulk apply tags to selected devices
- **GIVEN** a user selects multiple devices in the inventory list
- **WHEN** they use the bulk editor to add tags
- **THEN** the selected devices SHALL receive those tags

---

### Requirement: Tags Exposed for Sweep Targeting

The system SHALL expose device tags for sweep group targeting and query evaluation.

#### Scenario: Target devices by tag in sweep group
- **GIVEN** a sweep group targeting rule `tags.env = 'prod'`
- **WHEN** the group is compiled for a sweep config
- **THEN** only devices with `ocsf_devices.tags.env = 'prod'` SHALL be included
