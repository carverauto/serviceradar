## MODIFIED Requirements
### Requirement: Sysmon Profile Management

The web-ng UI MUST provide an interface for administrators to create, view, edit, and delete Sysmon Profiles.

#### Scenario: Navigate to Sysmon Profiles
- **GIVEN** an authenticated admin user
- **WHEN** they navigate to Settings → Sysmon Profiles
- **THEN** they see a list of all existing profiles
- **AND** the list shows profile name, description, sample interval, and assignment count

#### Scenario: Create new profile
- **GIVEN** an admin on the Sysmon Profiles page
- **WHEN** they click "Create Profile"
- **THEN** a form opens with fields for:
  - Name (required, unique)
  - Description (optional)
  - Sample Interval (dropdown: 1s, 5s, 10s, 30s, 1m, custom)
  - Enabled Metrics (checkboxes: CPU, Memory, Disk, Network, Processes)
  - Disk Paths (multi-input for paths like "/", "/data")
  - Thresholds (optional: warning/critical levels for CPU, Memory, Disk)
- **AND** they can save the profile

#### Scenario: Target query input updates builder
- **GIVEN** an admin editing a sysmon profile with the query builder open
- **WHEN** they paste a valid SRQL target query into the Target Query input
- **THEN** the builder filters update to match the parsed query
- **AND** the builder indicates the query is applied

#### Scenario: Unsupported SRQL leaves builder unsynced
- **GIVEN** the query builder is open
- **WHEN** the admin enters a target query that includes unsupported SRQL clauses
- **THEN** the Target Query input value is preserved
- **AND** the builder indicates it is not applied to the query

#### Scenario: Edit existing profile
- **GIVEN** an existing profile "High Performance"
- **WHEN** the admin clicks "Edit" on that profile
- **THEN** the form pre-populates with current values
- **AND** they can modify and save changes
- **AND** changes propagate to assigned devices on their next config refresh

#### Scenario: Delete profile with assignments
- **GIVEN** a profile "Legacy" assigned to 5 devices
- **WHEN** the admin attempts to delete it
- **THEN** a confirmation dialog shows "This profile is assigned to 5 devices"
- **AND** they must confirm reassignment to Default profile
- **AND** upon confirmation, affected devices receive Default profile

#### Scenario: View profile JSON preview
- **GIVEN** an admin editing a profile
- **WHEN** they click "Preview JSON"
- **THEN** they see the compiled JSON that agents will receive
- **AND** the preview updates live as they modify settings
