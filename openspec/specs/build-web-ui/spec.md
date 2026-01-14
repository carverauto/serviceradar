# build-web-ui Specification

## Purpose
TBD - created by archiving change remove-legacy-web-build. Update Purpose after archive.
## Requirements
### Requirement: Default builds exclude legacy Next.js UI outputs
The build system SHALL only build `serviceradar-web-ng` (Phoenix) UI artifacts. The legacy `serviceradar-web` (Next.js) source code and all associated build targets have been completely removed from the codebase.

#### Scenario: Bazel wildcard build produces web-ng only
- **GIVEN** a clean checkout
- **WHEN** `bazel build //... --config=remote` runs
- **THEN** `web-ng` artifacts are built
- **AND** no legacy `web/` directory or targets exist in the codebase.

#### Scenario: push_all publishes web-ng UI only
- **GIVEN** the release push workflow
- **WHEN** `bazel run //docker/images:push_all` completes
- **THEN** it publishes `serviceradar-web-ng` for the UI
- **AND** no `serviceradar-web` image exists in push targets.

### Requirement: Default deployments serve web-ng only
Default deployment manifests SHALL deploy the Phoenix `web-ng` UI. The legacy `serviceradar-web` service, Docker images, packaging, and CI workflows have been completely removed.

#### Scenario: Docker Compose uses web-ng
- **GIVEN** the default `docker-compose.yml`
- **WHEN** `docker compose up -d` is executed
- **THEN** the UI service is `web-ng`
- **AND** no legacy `Dockerfile.web` or `entrypoint-web.sh` exists.

#### Scenario: Helm/K8s defaults use web-ng
- **GIVEN** the default Helm chart and demo K8s manifests
- **WHEN** they are rendered/applied
- **THEN** UI resources reference `serviceradar-web-ng`
- **AND** no legacy web packaging or RPM specs exist.

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

### Requirement: Default Profile Protection

The system MUST provide a Default Sysmon Profile that cannot be deleted.

#### Scenario: Default profile exists
- **GIVEN** the Sysmon Profiles page
- **THEN** a "Default" profile always exists
- **AND** it is marked with a "System" badge

#### Scenario: Cannot delete default profile
- **GIVEN** the Default profile
- **WHEN** an admin views its actions
- **THEN** the "Delete" action is disabled or hidden
- **AND** a tooltip explains "System default cannot be deleted"

#### Scenario: Can modify default profile
- **GIVEN** the Default profile
- **WHEN** an admin clicks "Edit"
- **THEN** they can modify settings
- **AND** changes apply to all devices using the default

### Requirement: Profile Assignment to Devices

The UI MUST allow direct profile assignment to individual devices.

#### Scenario: Assign profile from device detail
- **GIVEN** an admin viewing a device detail page
- **WHEN** they click "Sysmon Profile" dropdown
- **THEN** they see a list of available profiles
- **AND** can select one to assign directly to this device

#### Scenario: Bulk assign profile to devices
- **GIVEN** an admin on the Devices list page
- **WHEN** they select multiple devices
- **AND** click "Bulk Actions" → "Assign Sysmon Profile"
- **THEN** they can select a profile to assign to all selected devices

#### Scenario: Clear device profile assignment
- **GIVEN** a device with directly assigned profile "Database"
- **WHEN** the admin clicks "Clear Assignment"
- **THEN** the device no longer has a direct profile
- **AND** it falls back to tag-based or default profile

### Requirement: Profile Assignment via Tags

The UI MUST allow assigning profiles to device tags for group-based configuration.

#### Scenario: Assign profile to tag
- **GIVEN** a tag "database-server" exists with 50 devices
- **WHEN** the admin navigates to Settings → Tags (or Sysmon Profiles → Tag Assignments)
- **AND** assigns "High Performance" profile to tag "database-server"
- **THEN** all 50 devices with that tag receive the "High Performance" configuration
- **AND** the assignment is stored for future devices gaining this tag

#### Scenario: View tag assignments
- **GIVEN** the Sysmon Profiles page
- **WHEN** the admin clicks "Tag Assignments" tab
- **THEN** they see a table of tag → profile mappings
- **AND** each row shows tag name, assigned profile, and device count

#### Scenario: Remove tag assignment
- **GIVEN** tag "production" is assigned profile "Prod Standard"
- **WHEN** the admin removes this assignment
- **THEN** devices with only this tag fall back to default profile
- **AND** devices with other tag assignments use their remaining profile

#### Scenario: Tag assignment priority
- **GIVEN** a device with tags "production" and "database"
- **AND** both tags have profile assignments
- **WHEN** the admin views the device detail
- **THEN** it shows which profile is effective
- **AND** explains the resolution reason (e.g., "Database profile (higher priority)")

### Requirement: Device Sysmon Status Visibility

The UI MUST show the sysmon configuration status for devices.

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

### Requirement: Agent Visibility Page

The UI MUST provide a dedicated view for managing agents and their sysmon status.

#### Scenario: Navigate to Agents view
- **GIVEN** an authenticated admin
- **WHEN** they navigate to Inventory → Agents (or similar)
- **THEN** they see a list of all registered agents
- **AND** columns include: Agent ID, Hostname, Last Seen, Sysmon Profile, Status

#### Scenario: Filter agents by sysmon profile
- **GIVEN** the Agents list page
- **WHEN** the admin filters by "Sysmon Profile = High Performance"
- **THEN** only agents using that profile are shown

#### Scenario: Filter agents by local override
- **GIVEN** the Agents list page
- **WHEN** the admin filters by "Config Source = Local"
- **THEN** only agents using local sysmon.json are shown
- **AND** this helps identify agents not centrally managed

### Requirement: Profile Usage Analytics

The UI MUST provide visibility into profile usage and distribution.

#### Scenario: Profile usage summary
- **GIVEN** the Sysmon Profiles page
- **THEN** each profile shows a count of devices/agents using it

#### Scenario: View devices using profile
- **GIVEN** a profile "Database" assigned to 25 devices
- **WHEN** the admin clicks the device count
- **THEN** they see a filtered list of those 25 devices

### Requirement: Ash Resource Backend

The backend MUST implement Ash resources for sysmon profile management following established patterns.

#### Scenario: SysmonProfile resource
- **GIVEN** the SysmonProfile Ash resource
- **THEN** it includes:
  - `id` (UUID, primary key)
  - `name` (string, unique per tenant)
  - `description` (string, optional)
  - `sample_interval` (integer, milliseconds)
  - `collect_cpu` (boolean, default true)
  - `collect_memory` (boolean, default true)
  - `collect_disk` (boolean, default true)
  - `collect_network` (boolean, default false)
  - `collect_processes` (boolean, default false)
  - `disk_paths` (array of strings)
  - `process_top_n` (integer, default 10)
  - `thresholds` (embedded map)
  - `is_default` (boolean, default false)
  - `tenant_id` (UUID, for multi-tenancy)

#### Scenario: SysmonProfileAssignment resource
- **GIVEN** the SysmonProfileAssignment Ash resource
- **THEN** it includes:
  - `id` (UUID, primary key)
  - `profile_id` (belongs_to SysmonProfile)
  - `device_id` (belongs_to Device, nullable)
  - `tag_name` (string, nullable - for tag-based assignments)
  - `priority` (integer, for multiple tag matches)
  - `tenant_id` (UUID)
- **AND** either device_id or tag_name must be set (not both, not neither)

#### Scenario: SysmonCompiler integration
- **GIVEN** the AgentConfig compiler system
- **WHEN** an agent requests sysmon configuration
- **THEN** the SysmonCompiler resolves the effective profile
- **AND** compiles it to JSON matching the agent schema
- **AND** the ConfigInvalidationNotifier triggers on profile changes

