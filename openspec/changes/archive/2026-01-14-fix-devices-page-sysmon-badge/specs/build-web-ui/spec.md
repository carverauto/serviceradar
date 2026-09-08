## MODIFIED Requirements
### Requirement: Device Sysmon Status Visibility

The UI MUST show the sysmon configuration status for devices. The UI MUST render the Devices list and device detail views even when sysmon profile or status data is missing or malformed, and MUST display a fallback label and neutral status indicator when data is unavailable.

#### Scenario: Device list sysmon column
- **GIVEN** the Devices list page
- **WHEN** the admin enables the "Sysmon" column
- **THEN** each device row shows:
  - Profile name (or "Default")
  - Status indicator (configured, local override, disabled)

#### Scenario: Device detail sysmon section
- **GIVEN** a device detail page
- **THEN** a "System Monitoring" section shows:
  - Current profile name and source (direct, tag, default)
  - Configuration summary (interval, enabled metrics)
  - Local override indicator if agent is using local config
  - Last config fetch timestamp

#### Scenario: Local override indicator
- **GIVEN** a device where the agent is using local sysmon.json
- **WHEN** the admin views the device
- **THEN** they see a badge "Local Override"
- **AND** a tooltip explains "Agent is using local configuration file"

#### Scenario: Missing sysmon profile data
- **GIVEN** a device record without sysmon profile assignment or status fields
- **WHEN** the Devices list page renders the Sysmon column
- **THEN** the row SHALL render a fallback label such as "Unassigned"
- **AND** the page SHALL render without error
