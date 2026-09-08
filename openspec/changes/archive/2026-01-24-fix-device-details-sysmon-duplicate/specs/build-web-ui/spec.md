## MODIFIED Requirements

### Requirement: Device Details Metric Sections

The device details page SHALL display sysmon metrics in organized sections, with each metric type rendered exactly once.

Process metrics SHALL be rendered exclusively via the `process_metrics_section` component, which displays a command-line icon in the card header.

The `metric_sections` loop SHALL NOT include a separate "processes" section to avoid duplicate rendering.

#### Scenario: Process metrics displayed once with icon
- **WHEN** a device has sysmon process metrics available
- **AND** `sysmon_metrics_visible` is true
- **THEN** the process list is rendered exactly once
- **AND** the process card header includes the command-line icon

#### Scenario: No duplicate process sections
- **WHEN** viewing the device details page for a device with sysmon data
- **THEN** no duplicate process cards appear
- **AND** only the `process_metrics_section` component renders process data
