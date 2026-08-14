## ADDED Requirements

### Requirement: Composite Verdict Northbound Export

The Armis northbound integration SHALL support exporting a selected composite
check's result for each device, as either the verdict slug or the fixed status
enum, using the existing northbound update path.

The exported check and value form SHALL be operator-selected configuration, and
the selection SHALL be visible in northbound run status.

#### Scenario: Export verdict slugs

- **GIVEN** northbound export configured for check `pci-isolation` in verdict
  form
- **WHEN** a northbound run executes
- **THEN** each in-scope device's payload SHALL carry its verdict slug

#### Scenario: Export status enum

- **GIVEN** northbound export configured for check `pci-isolation` in status form
- **WHEN** a northbound run executes
- **THEN** each in-scope device's payload SHALL carry its status value

#### Scenario: Devices outside the check scope are omitted

- **GIVEN** a device with no result row for the selected check
- **WHEN** a northbound run executes
- **THEN** no composite value SHALL be sent for that device
- **AND** the run SHALL NOT send a placeholder or empty value

#### Scenario: Selection is visible in run status

- **WHEN** an operator views a northbound run summary
- **THEN** the selected composite check and value form SHALL be displayed
