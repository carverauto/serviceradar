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
- **AND** they must confirm clearing those assignments
- **AND** upon confirmation, affected devices have no direct sysmon profile assignment

#### Scenario: View profile JSON preview
- **GIVEN** an admin editing a profile
- **WHEN** they click "Preview JSON"
- **THEN** they see the compiled JSON that agents will receive
- **AND** the preview updates live as they modify settings

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
- **AND** it falls back to tag-based assignment when available
- **AND** it is otherwise unassigned

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
- **THEN** devices with only this tag become unassigned
- **AND** devices with other tag assignments use their remaining profile

#### Scenario: Tag assignment priority
- **GIVEN** a device with tags "production" and "database"
- **AND** both tags have profile assignments
- **WHEN** the admin views the device detail
- **THEN** it shows which profile is effective
- **AND** explains the resolution reason (e.g., "Database profile (higher priority)")

### Requirement: Device Sysmon Status Visibility

The UI MUST show the sysmon configuration status for devices. The UI MUST render the Devices list and device detail views even when sysmon profile or status data is missing or malformed, and MUST display a fallback label and neutral status indicator when data is unavailable.

#### Scenario: Device list sysmon column
- **GIVEN** the Devices list page
- **WHEN** the admin enables the "Sysmon" column
- **THEN** each device row shows:
  - Profile name (or "Unassigned")
  - Status indicator (configured, local override, disabled)

#### Scenario: Device detail sysmon section
- **GIVEN** a device detail page
- **THEN** a "System Monitoring" section shows:
  - Current profile name and source (direct, tag, unassigned)
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

### Requirement: Integration Sources Under Network Settings

The web-ng UI SHALL display the Integrations management page as a sub-tab under Settings -> Network, alongside Sweep Profiles, Discovery, and SNMP.

#### Scenario: Navigate to Integrations via Network sub-nav
- **GIVEN** an authenticated user on the Settings page
- **WHEN** they click the "Network" tab
- **THEN** they see sub-navigation tabs: Sweep Profiles, Discovery, SNMP, Integrations
- **AND** clicking "Integrations" navigates to `/settings/networks/integrations`

#### Scenario: Integrations removed from top-level Settings tabs
- **GIVEN** an authenticated user viewing Settings
- **WHEN** they view the top-level Settings navigation
- **THEN** they do NOT see "Integrations" as a top-level tab
- **AND** they see: Cluster, Network, Agents, Events, Edge Ops, Jobs

#### Scenario: Integration CRUD routes under network path
- **GIVEN** the integration management functionality
- **THEN** the following routes SHALL be available:
  - `/settings/networks/integrations` - list all integration sources
  - `/settings/networks/integrations/new` - create new integration source
  - `/settings/networks/integrations/:id` - view integration details
  - `/settings/networks/integrations/:id/edit` - edit integration source

#### Scenario: Network tab active state includes integrations
- **GIVEN** a user on `/settings/networks/integrations`
- **WHEN** they view the Settings navigation
- **THEN** the "Network" top-level tab is highlighted as active
- **AND** the "Integrations" sub-tab is highlighted as active

### Requirement: Sysmon metrics only for eligible devices
The device detail view SHALL show sysmon metrics panels only when the device has sysmon metrics data or a sysmon status record.

#### Scenario: Non-sysmon device detail view
- **GIVEN** a device without sysmon metrics data or sysmon status
- **WHEN** an admin views the device detail page
- **THEN** no sysmon metrics panels are displayed

#### Scenario: Sysmon device detail view
- **GIVEN** a device with sysmon metrics data or sysmon status
- **WHEN** an admin views the device detail page
- **THEN** sysmon metrics panels are displayed

### Requirement: Sysmon metrics rendered as graphs
The device detail view SHALL render sysmon CPU, memory, and disk metrics as graphs with normalized utilization semantics.

#### Scenario: Sysmon CPU metrics visualization
- **GIVEN** a device with sysmon CPU metrics
- **WHEN** an admin views the device detail page
- **THEN** the CPU graph shows utilization as a percentage from 0 to 100
- **AND** the current CPU utilization value is visible in the card header

#### Scenario: Sysmon memory metrics visualization
- **GIVEN** a device with sysmon memory metrics
- **WHEN** an admin views the device detail page
- **THEN** the memory graph shows used and available memory as distinct series

#### Scenario: Sysmon disk metrics visualization
- **GIVEN** a device with sysmon disk metrics
- **WHEN** an admin views the device detail page
- **THEN** disk graphs are grouped by disk or partition (mount/device)
- **AND** each graph shows used versus total capacity rather than per-file values

### Requirement: Suppress low-value auto visualizations
The device detail view SHALL NOT auto-create a visualization for the dimension "type_id by modified".

#### Scenario: Default device detail visualizations
- **GIVEN** an admin opens a device detail page
- **WHEN** default visualizations are generated
- **THEN** no visualization is created for "Categories: type_id by modified"

### Requirement: Interface Row Selection

The interfaces table SHALL support row selection for bulk operations.

#### Scenario: Select single interface
- **GIVEN** a user viewing the interfaces table in device details
- **WHEN** they click the checkbox on an interface row
- **THEN** the row is selected and highlighted
- **AND** the bulk action toolbar becomes visible

#### Scenario: Select all interfaces
- **GIVEN** a user viewing the interfaces table
- **WHEN** they click the select-all checkbox in the header
- **THEN** all visible interface rows are selected
- **AND** the bulk action toolbar shows the count of selected items

#### Scenario: Deselect all interfaces
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks the select-all checkbox again or clicks "Clear selection"
- **THEN** all interfaces are deselected
- **AND** the bulk action toolbar is hidden

---

### Requirement: Interface Bulk Edit

The interfaces table SHALL provide bulk edit functionality for selected interfaces.

#### Scenario: Bulk enable metrics collection
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks "Bulk Edit" and enables "Metrics Collection"
- **THEN** all selected interfaces have metrics collection enabled
- **AND** the metrics indicator icon appears on those rows

#### Scenario: Bulk favorite interfaces
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks "Bulk Edit" and clicks "Add to Favorites"
- **THEN** all selected interfaces are marked as favorites
- **AND** the star icon fills in on those rows

#### Scenario: Bulk apply tags
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks "Bulk Edit" and adds tags
- **THEN** the specified tags are applied to all selected interfaces

---

### Requirement: Interface Favorite Icon

The interfaces table SHALL display a favorite/star icon column that users can click to toggle favorite status.

#### Scenario: Favorite an interface
- **GIVEN** an interface row with an unfilled star icon
- **WHEN** the user clicks the star icon
- **THEN** the star fills in to indicate favorited status
- **AND** the favorite state is persisted to the backend

#### Scenario: Unfavorite an interface
- **GIVEN** an interface row with a filled star icon
- **WHEN** the user clicks the star icon
- **THEN** the star becomes unfilled
- **AND** the interface is removed from favorites

---

### Requirement: Interface Details Screen

The system SHALL provide a dedicated interface details page showing comprehensive interface information.

#### Scenario: Navigate to interface details
- **GIVEN** a user viewing the interfaces table
- **WHEN** they click on an interface row or the details icon
- **THEN** they navigate to `/devices/:device_id/interfaces/:interface_id`
- **AND** the interface details page loads

#### Scenario: Display interface properties
- **GIVEN** the interface details page
- **THEN** it SHALL display:
  - Interface name and description
  - Interface ID
  - OID information
  - Interface type (human-readable)
  - Speed and duplex settings
  - MAC address
  - IP addresses
  - Operational and admin status with colorized indicators

#### Scenario: Enable metrics collection from details
- **GIVEN** the interface details page for an interface without metrics collection
- **WHEN** the user toggles the "Enable Metrics Collection" switch
- **THEN** metrics collection is enabled for this interface
- **AND** the toggle reflects the enabled state

---

### Requirement: Interface Metrics Collection Indicator

The interfaces table SHALL display an icon indicating whether metrics collection is enabled for each interface, and the icon SHALL be clickable to navigate to interface details.

#### Scenario: Metrics enabled indicator
- **GIVEN** an interface with metrics collection enabled
- **WHEN** the interfaces table renders
- **THEN** a metrics/chart icon is displayed in that row
- **AND** the icon is visually distinct (filled or colored)

#### Scenario: Click metrics indicator
- **GIVEN** an interface row with the metrics indicator icon
- **WHEN** the user clicks the metrics icon
- **THEN** they navigate to the interface details page
- **AND** the metrics/graphs section is visible

#### Scenario: No metrics indicator
- **GIVEN** an interface without metrics collection enabled
- **WHEN** the interfaces table renders
- **THEN** the metrics indicator is either absent or shown as disabled/outline style

---

### Requirement: Interface Status Colorized Display

The interfaces table status column SHALL display operational and admin status using colorized labels/badges that are color-blind accessible.

#### Scenario: Operational up status
- **GIVEN** an interface with operational status "up"
- **WHEN** the interfaces table renders
- **THEN** the status shows a green badge with "Up" text
- **AND** includes an upward arrow or checkmark icon for color-blind accessibility

#### Scenario: Operational down status
- **GIVEN** an interface with operational status "down"
- **WHEN** the interfaces table renders
- **THEN** the status shows a red badge with "Down" text
- **AND** includes a downward arrow or X icon for color-blind accessibility

#### Scenario: Admin disabled status
- **GIVEN** an interface with admin status "down" (disabled)
- **WHEN** the interfaces table renders
- **THEN** the status shows a gray or yellow badge with "Admin Down" text
- **AND** includes a pause or disabled icon

#### Scenario: Nil status handling
- **GIVEN** an interface with nil/unknown status value
- **WHEN** the interfaces table renders
- **THEN** the status shows a neutral badge with "Unknown" text
- **AND** does not display "nil" literally

---

### Requirement: Interface Type Human-Readable Mapping

The interfaces table type column SHALL display human-readable interface type names instead of raw IANA ifType values.

#### Scenario: Ethernet interface type
- **GIVEN** an interface with type `ethernetCsmacd` (ifType 6)
- **WHEN** the interfaces table renders
- **THEN** the type column displays "Ethernet"

#### Scenario: Loopback interface type
- **GIVEN** an interface with type `softwareLoopback` (ifType 24)
- **WHEN** the interfaces table renders
- **THEN** the type column displays "Loopback"

#### Scenario: Unknown interface type
- **GIVEN** an interface with an unmapped ifType value
- **WHEN** the interfaces table renders
- **THEN** the type column displays the original value with "(Unknown)" suffix

---

### Requirement: Interface ID Column

The interfaces table SHALL include an interface ID column.

#### Scenario: Display interface ID
- **GIVEN** the interfaces table with interface ID column enabled
- **WHEN** the table renders
- **THEN** each row displays the interface's unique identifier

---

### Requirement: Favorited Interface Metrics Visualization

The device details view SHALL display metrics visualizations for favorited interfaces with metrics collection enabled, positioned above the interfaces table.

#### Scenario: Display metrics for favorited interfaces
- **GIVEN** a device with interfaces that are favorited AND have metrics collection enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** a metrics visualization section appears above the interfaces table
- **AND** displays graphs for each favorited interface's metrics

#### Scenario: Auto-select visualization type
- **GIVEN** a favorited interface with counter-type metrics (e.g., bytes in/out)
- **WHEN** the visualization renders
- **THEN** a line or area chart is displayed showing the metric over time

#### Scenario: Gauge metric visualization
- **GIVEN** a favorited interface with gauge-type metrics (e.g., utilization percentage)
- **WHEN** the visualization renders
- **THEN** a gauge or percentage chart is displayed

#### Scenario: No favorited interfaces
- **GIVEN** a device with no favorited interfaces with metrics enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** the metrics visualization section is not displayed
- **OR** shows an empty state message

---

### Requirement: Interface Threshold Configuration

The interface details page SHALL allow users to configure thresholds on utilization metrics that generate events when exceeded.

#### Scenario: Create utilization threshold
- **GIVEN** the interface details page for an interface with metrics enabled
- **WHEN** the user configures a threshold (e.g., "bandwidth utilization > 80%")
- **THEN** the threshold is saved
- **AND** the system will generate an event when the condition is met

#### Scenario: Threshold generates event
- **GIVEN** an interface with a configured threshold
- **WHEN** the metric value exceeds the threshold
- **THEN** an event is created in the events system
- **AND** the event references the interface and threshold condition

---

### Requirement: Interface Alert Creation

The interface details page SHALL allow users to create alerts on interface threshold events using the existing alert editor component.

#### Scenario: Create alert from threshold
- **GIVEN** a threshold configured on an interface
- **WHEN** the user clicks "Create Alert" on the threshold
- **THEN** the alert editor opens pre-populated with the threshold event source
- **AND** the user can configure alert parameters (e.g., "exceeds threshold for 5 minutes")

#### Scenario: Alert editor reuse
- **GIVEN** the alert creation flow on interface details
- **THEN** it SHALL use the same alert editor component as the Settings page
- **AND** support the same alert configuration options

### Requirement: Interface metrics charts render error counters
The web UI SHALL render interface error counter charts when `in_errors` and `out_errors` are present in SRQL interface metrics responses.

#### Scenario: Error counters displayed
- **GIVEN** the interface metrics SRQL response includes `in_errors` and `out_errors`
- **WHEN** a user views the interface metrics section
- **THEN** the UI shows charts for inbound and outbound errors

#### Scenario: Empty-state for missing error counters
- **GIVEN** the interface metrics SRQL response includes `in_errors: null` and `out_errors: null`
- **WHEN** a user views the interface metrics section
- **THEN** the UI shows an empty-state message indicating error counters are not yet available

### Requirement: Interface metrics timeseries charts
The device interface metrics view SHALL render SNMP interface traffic as timeseries charts with a time axis, a rate axis, and gridlines for readability.

#### Scenario: Interface traffic chart axes
- **GIVEN** a device interface has SNMP traffic metrics available
- **WHEN** the interface metrics charts are rendered
- **THEN** the chart SHALL show a time-based X axis and a rate-based Y axis
- **AND** the chart SHALL include gridlines aligned to the axes

#### Scenario: Counter-based traffic rate calculation
- **GIVEN** SNMP interface traffic metrics are stored as counters (ifIn/OutOctets or ifHCIn/OutOctets)
- **WHEN** the interface metrics chart is rendered
- **THEN** the chart SHALL display per-second rates computed from consecutive counter deltas

### Requirement: Device details interface tab uses SRQL
The device details UI SHALL fetch interfaces via SRQL `in:interfaces`. The Interfaces tab SHALL be visible when SRQL returns interface rows OR when the device has at least one network discovery job targeting it. When SRQL returns no interface rows and the tab is visible, the UI SHALL present an empty-state that includes discovery diagnostics (last run timestamp and status) and a link to the relevant discovery job settings.

#### Scenario: Interfaces tab visible with data
- **GIVEN** SRQL returns interface observations for the device
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is visible and renders the SRQL interface rows

#### Scenario: Interfaces tab visible without data
- **GIVEN** SRQL returns no interface observations for the device
- **AND** the device has a discovery job targeting it
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is visible
- **AND** the UI shows an empty-state message including last discovery run timestamp and status
- **AND** the UI provides a link to the discovery job edit page

#### Scenario: Interfaces tab hidden for non-discovery devices
- **GIVEN** SRQL returns no interface observations for the device
- **AND** the device has no discovery job targeting it
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is hidden

### Requirement: Device Detail Shows IP Aliases
The web-ng device detail page SHALL display IP alias records for the device, including alias state and last-seen metadata.

#### Scenario: Device detail displays alias table
- **GIVEN** a device with IP aliases recorded by DIRE
- **WHEN** an admin views the device detail page
- **THEN** the page SHALL list alias IPs with state, last seen time, and sighting count

#### Scenario: Hide stale aliases by default
- **GIVEN** a device with confirmed and stale alias records
- **WHEN** the device detail page loads
- **THEN** stale or archived aliases SHALL be hidden by default
- **AND** the user may toggle to show them

### Requirement: SNMP profile list shows target counts
The web-ng SNMP Profiles list SHALL display a target count for each profile based on executing the normalized SRQL `target_query`. When a count cannot be computed, the UI SHALL show "Unknown" instead of a misleading zero and surface the error state.

#### Scenario: List shows computed target counts
- **GIVEN** an admin viewing Settings → SNMP Profiles
- **WHEN** the list renders
- **THEN** each profile row shows "N targets" based on the SRQL target query

#### Scenario: Invalid query shows unknown
- **GIVEN** a profile with an invalid SRQL `target_query`
- **WHEN** the list renders
- **THEN** the targets column shows "Unknown"
- **AND** the UI indicates that the query could not be evaluated

### Requirement: Target preview labels align with targeting mode
The SNMP profile editor SHALL label target preview counts as device targets and indicate whether the SRQL query targets devices or interfaces. Empty or missing queries SHALL default to device targeting.

#### Scenario: Empty query defaults to device targeting
- **GIVEN** an SNMP profile with no `target_query`
- **WHEN** the editor renders the preview count
- **THEN** the UI indicates device targeting and displays the device target count

#### Scenario: Interface targeting indicator
- **GIVEN** an SNMP profile with `target_query: "in:interfaces type:ethernet"`
- **WHEN** the editor renders the preview count
- **THEN** the UI indicates interface targeting while still reporting device target counts

### Requirement: God-View directional flow rendering uses real telemetry only
God-View SHALL render bidirectional edge particles only from real directional edge telemetry fields and SHALL NOT synthesize reverse-direction flow from aggregate edge metrics.

#### Scenario: Directional telemetry for both sides
- **GIVEN** a topology edge payload with A→B and B→A directional rates
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL draw both directional streams using those real directional values

#### Scenario: Directional telemetry on one side only
- **GIVEN** a topology edge payload with only one directional side populated
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL draw only the available direction
- **AND** SHALL NOT synthesize a reverse stream from aggregate values

#### Scenario: No directional telemetry fields present
- **GIVEN** a topology edge payload that includes only aggregate flow metrics
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL use single-stream aggregate behavior
- **AND** SHALL NOT invent directional lanes

#### Scenario: Telemetry-ineligible topology edge
- **GIVEN** a topology edge payload marked telemetry-ineligible due to missing interface attribution or required counters
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL avoid showing misleading packet activity for that edge
- **AND** SHALL preserve structural edge visibility for topology context

### Requirement: God-View packet stream density and tube coverage parity
God-View SHALL render packet streams with dense tube-aligned coverage comparable to the approved deckgl PoC visual profile while preserving zoom-tier readability.

#### Scenario: Mid-zoom density and tube fill
- **GIVEN** topology edges with active telemetry at mid zoom
- **WHEN** packet layers are rendered
- **THEN** particle density SHALL fill the edge tube without appearing sparse
- **AND** particle spread SHALL remain near the visual edge tube boundary without visibly overflowing it

#### Scenario: Zoomed-out readability
- **GIVEN** the user zooms far out
- **WHEN** packet layers are rendered
- **THEN** particle visibility and spread SHALL avoid neon-line saturation artifacts
- **AND** edge structures SHALL remain legible as topology links

#### Scenario: Zoomed-in readability
- **GIVEN** the user zooms far in
- **WHEN** packet layers are rendered
- **THEN** particles SHALL remain visibly distinct and readable
- **AND** zoom scaling SHALL not reduce particles below a practical visibility floor

### Requirement: NetFlow visualize route canonicalization
The web-ng UI SHALL treat `/flows` as the canonical route for `ServiceRadarWebNGWeb.NetflowLive.Visualize`. All in-page NetFlow navigation generated from that LiveView (including `push_patch`, SRQL builder submit/apply paths, pagination links, and table links) MUST resolve to `/flows` so patches stay within the active root view.

#### Scenario: NetFlow chart/state updates patch within the active LiveView
- **GIVEN** an authenticated user is on the NetFlow visualize page
- **WHEN** they change visualize state, run a query, or paginate results
- **THEN** the LiveView patches to a `/flows` URL
- **AND** the session does not raise a `cannot push_patch/2` root-view mismatch

#### Scenario: Legacy netflow aliases are removed
- **GIVEN** a user opens `/netflow` or `/netflows`
- **WHEN** the request is handled
- **THEN** the application does not serve a NetFlow LiveView at those paths
- **AND** NetFlow visualization is available only at `/flows`

### Requirement: God-View node detail card shows node identity and network context
The God-View deck.gl node-detail surfaces (click selection card and node tooltip) SHALL render node identity and network context from the topology payload when those fields are present, including `id`, `ip`, `type`, `vendor`, `model`, `last_seen`, `asn`, and geographic location fields.

#### Scenario: Node detail card includes IP and metadata
- **GIVEN** a God-View node payload includes `details.ip` and other metadata fields
- **WHEN** an operator clicks that node in the deck.gl canvas
- **THEN** the node detail card SHALL display the node IP address and available metadata values
- **AND** the tooltip for that same node SHALL show the same IP/type context

#### Scenario: Missing fields render explicit fallback values
- **GIVEN** a God-View node payload is missing one or more detail metadata fields
- **WHEN** an operator opens node details from the deck.gl canvas
- **THEN** the node detail card SHALL remain visible
- **AND** each missing field SHALL render an explicit fallback value (for example `unknown` or `—`) rather than rendering blank/undefined content

#### Scenario: Regression coverage for detail metadata mapping
- **GIVEN** automated God-View frontend tests are executed
- **WHEN** node-detail rendering logic is validated
- **THEN** tests SHALL fail if IP or required mapped detail fields are dropped from the rendered detail card for payloads that include those fields

### Requirement: Reusable Flow Stat Components
The web-ng UI SHALL provide a `flow_stat_components` module containing pure Phoenix function components for displaying flow statistics. Components MUST accept data via assigns (not fetch data internally) and emit drill-down events via configurable callback attrs. Components MUST render correctly in both light and dark daisyUI themes.

#### Scenario: Stat card renders KPI with trend
- **WHEN** a LiveView renders `<.stat_card title="Total Bandwidth" value={@bandwidth} unit="bps" trend={+12.5} />`
- **THEN** the card displays the title, formatted value with SI prefix, unit label, and a trend indicator (up/down arrow with percentage)

#### Scenario: Top-N table renders ranked rows with drill-down
- **WHEN** a LiveView renders `<.top_n_table rows={@top_talkers} columns={[:rank, :ip, :bytes, :packets]} on_row_click={&handle_drill_down/1} />`
- **THEN** the table displays numbered rows sorted by the ranking metric
- **AND** clicking a row invokes the callback with the row data

#### Scenario: Stat components embedded in device details
- **GIVEN** the device details flows tab LiveView
- **WHEN** it renders `<.top_n_table>` and `<.stat_card>` with device-scoped flow data
- **THEN** the components render identically to their dashboard usage with no code duplication

#### Scenario: Traffic sparkline renders inline mini-chart
- **WHEN** a LiveView renders `<.traffic_sparkline data={@timeseries} />`
- **THEN** a small area chart renders inline without axes or legends
- **AND** the chart is responsive to container width

### Requirement: Flows Dashboard Homepage
The web-ng UI SHALL provide a dashboard homepage at `/flows` displaying aggregated flow statistics in a widget grid layout. The dashboard MUST show: total bandwidth, active flow count, unique talkers count, top-N talkers, top-N listeners, top-N conversations, top-N applications, top-N protocols, and a traffic-over-time chart.

#### Scenario: Dashboard loads with default time window
- **GIVEN** an authenticated user navigates to `/flows`
- **WHEN** the page loads
- **THEN** the dashboard displays stat cards and top-N tables for the default time window (last 1 hour)
- **AND** data is fetched from the appropriate CAGG or raw hypertable based on the time window

#### Scenario: Time window change refreshes all widgets
- **GIVEN** the dashboard is displaying stats for "Last 1h"
- **WHEN** the user selects "Last 7d" from the time window selector
- **THEN** all stat cards, tables, and charts refresh with data from the 7-day window
- **AND** the SRQL engine auto-selects the 1-hour CAGG for efficiency

#### Scenario: Drill-down from top talker to visualize
- **GIVEN** the dashboard shows "Top 10 Talkers"
- **WHEN** the user clicks on IP `10.1.5.42` in the table
- **THEN** the browser navigates to `/flows/visualize?nf=...` with an SRQL filter for `src_ip:10.1.5.42`
- **AND** the visualize page loads with the filter pre-applied

#### Scenario: Units selector changes display format
- **GIVEN** the dashboard is showing bandwidth in bits/sec
- **WHEN** the user switches to packets/sec
- **THEN** all bandwidth-related stat cards and charts update to display packet rates

### Requirement: Flows Route Structure
The web-ng router SHALL serve the flows dashboard at `/flows` and the visualization page at `/flows/visualize`. Requests to `/flows` with a `nf=` state parameter SHALL redirect to `/flows/visualize` preserving all query parameters.

#### Scenario: Clean navigation to dashboard
- **GIVEN** an authenticated user
- **WHEN** they navigate to `/flows` without query parameters
- **THEN** the flows dashboard homepage loads

#### Scenario: Backward-compatible redirect for visualize URLs
- **GIVEN** a bookmarked URL `/flows?nf=v1-abc123`
- **WHEN** the user navigates to that URL
- **THEN** they are redirected to `/flows/visualize?nf=v1-abc123`
- **AND** the visualize page loads with the preserved state

### Requirement: Flow Unit Formatting
The web-ng UI SHALL provide unit formatting helpers that convert raw byte/packet counts to human-readable strings with SI prefix abbreviation. Supported unit modes: bits/sec, bytes/sec, packets/sec. The helpers MUST be usable from any LiveView or component.

#### Scenario: Large bandwidth formatted with SI prefix
- **WHEN** the formatter receives `1_234_567_890` bytes/sec in bits/sec mode
- **THEN** it returns `"9.88 Gbps"`

#### Scenario: Small packet rate formatted
- **WHEN** the formatter receives `42_300` packets/sec in pps mode
- **THEN** it returns `"42.3 Kpps"`

### Requirement: Operators can inspect camera analysis workers in web-ng
The system SHALL provide an operator-facing `web-ng` surface to inspect registered camera analysis workers.

#### Scenario: Operator views worker status
- **GIVEN** registered camera analysis workers exist
- **WHEN** an authorized operator opens the worker management surface
- **THEN** the UI SHALL show worker identity, capabilities, enabled state, and current health state
- **AND** SHALL show recent failure or failover-relevant metadata when present

### Requirement: Camera Analysis Worker Management Includes Probe Settings
The operator-facing worker management surface SHALL expose worker probe configuration alongside identity, health, and capability metadata.

#### Scenario: Operator inspects a worker
- **WHEN** an operator views a registered camera analysis worker
- **THEN** the surface shows the worker probe endpoint and timeout configuration

#### Scenario: Operator updates probe settings
- **WHEN** an operator creates or updates a registered camera analysis worker
- **THEN** the management surface accepts and persists supported probe configuration fields

### Requirement: Camera Analysis Worker Surface Shows Recent Probe Activity
The operator-facing camera analysis worker management surface SHALL show recent active probe outcomes for each worker.

#### Scenario: Operator inspects a worker with recent probe failures
- **WHEN** a worker has recent failed probes
- **THEN** the surface shows recent failure timestamps and normalized reasons

#### Scenario: Operator inspects a stable worker
- **WHEN** a worker has recent successful probes
- **THEN** the surface shows recent successful probe activity

### Requirement: Camera Analysis Worker Ops SHALL Show Flapping State
The authenticated camera analysis worker operator surface SHALL show derived worker flapping state alongside health and recent probe activity.

#### Scenario: Worker is flapping
- **WHEN** an operator views a worker whose derived flapping state is true
- **THEN** the surface SHALL display a visible flapping label
- **AND** it SHALL show the bounded transition count or equivalent flapping context

#### Scenario: Worker is stable
- **WHEN** an operator views a worker whose derived flapping state is false
- **THEN** the surface SHALL not display the worker as flapping

### Requirement: Camera Analysis Worker API SHALL Expose Flapping Metadata
The authenticated worker management API SHALL expose derived flapping state and normalized flapping metadata.

#### Scenario: API returns worker flapping metadata
- **WHEN** a client reads one or more registered camera analysis workers
- **THEN** each worker response SHALL include flapping state
- **AND** the response SHALL include enough bounded metadata to explain why the worker is or is not considered flapping

### Requirement: Camera Analysis Worker Ops SHALL Show Summarized Alert State
The authenticated camera analysis worker management surface SHALL show summarized worker alert state when bounded degradation thresholds are active.

#### Scenario: Worker has an active alert
- **WHEN** an operator views a worker with an active thresholded alert state
- **THEN** the worker surface SHALL display that alert state prominently
- **AND** it SHALL show enough normalized context to explain the active alert

#### Scenario: Worker has no active alert
- **WHEN** an operator views a worker without an active thresholded alert state
- **THEN** the worker surface SHALL indicate that no thresholded alert is active

### Requirement: Worker ops surface can correlate routed alerts
The authenticated camera analysis worker management surface SHALL expose enough alert-routing context to correlate a worker's current derived alert state with standard observability alerts.

#### Scenario: Worker has a routed alert
- **WHEN** an operator views a worker with an active routed worker alert
- **THEN** the surface SHALL show enough normalized alert context to explain that routed alert state
- **AND** it SHALL allow the operator to recognize that the worker alert is also present in the standard observability flow

#### Scenario: Worker has no routed alert
- **WHEN** an operator views a worker without an active routed worker alert
- **THEN** the surface SHALL not claim that a routed alert is active

### Requirement: Worker ops surface shows current assignments
The authenticated camera analysis worker management surface SHALL show current assignment visibility for each registered worker.

#### Scenario: Worker has active branches
- **WHEN** an operator views a worker with active relay-scoped analysis branches
- **THEN** the surface SHALL show the worker's active assignment count
- **AND** it SHALL display bounded current assignment details

#### Scenario: Worker is idle
- **WHEN** an operator views a worker with no active assignments
- **THEN** the surface SHALL indicate that the worker is currently idle

### Requirement: Worker management API returns assignment visibility
The authenticated worker management API SHALL expose current assignment visibility for registered camera analysis workers.

#### Scenario: API returns assignment counts
- **WHEN** a client reads one or more registered camera analysis workers
- **THEN** each worker response SHALL include the active assignment count
- **AND** it SHALL include bounded current assignment details when any are active

### Requirement: Worker ops surface shows notification-policy context
The authenticated camera analysis worker management surface SHALL show whether an active routed worker alert is participating in the standard notification-policy path.

#### Scenario: Worker alert is notification-eligible
- **WHEN** an operator views a worker with an active routed alert that is eligible for standard notification handling
- **THEN** the surface SHALL show normalized notification-policy context for that worker alert

#### Scenario: Worker has no active routed alert
- **WHEN** an operator views a worker without an active routed alert
- **THEN** the surface SHALL not imply that notification-policy routing is active

### Requirement: Worker ops surface shows notification audit state
The authenticated camera analysis worker management surface SHALL show bounded notification audit state for active routed worker alerts.

#### Scenario: Worker has active routed alert with notifications
- **WHEN** an operator views a worker with an active routed alert
- **THEN** the surface SHALL show current notification audit fields such as notification count and last notification time

#### Scenario: Worker has no active routed alert
- **WHEN** an operator views a worker without an active routed alert
- **THEN** the surface SHALL not imply that notification delivery has occurred

### Requirement: Camera viewers negotiate playback transport
The UI SHALL select a playback transport for each camera relay session based on browser capabilities and the transports advertised by the relay session.

#### Scenario: Browser supports the preferred direct playback path
- **GIVEN** a relay session advertises a direct low-latency playback transport
- **AND** the browser reports support for that transport
- **WHEN** the viewer initializes
- **THEN** the UI SHALL use the preferred direct playback transport

#### Scenario: Browser falls back to a portable playback path
- **GIVEN** a relay session advertises both a preferred direct playback transport and a portable fallback transport
- **AND** the browser does not support the preferred direct transport
- **WHEN** the viewer initializes
- **THEN** the UI SHALL select the fallback transport
- **AND** the viewer SHALL remain bound to the same relay session state

### Requirement: Unsupported browser state is explicit
The camera viewer UI SHALL show an explicit unsupported-browser state when no advertised playback transport is usable in the current browser.

#### Scenario: Browser supports no advertised transport
- **GIVEN** a relay session is active
- **AND** the browser does not support any transport advertised for that session
- **WHEN** the viewer initializes
- **THEN** the UI SHALL show that playback is unsupported in the current browser
- **AND** SHALL continue to display relay session status and termination details
- **AND** SHALL NOT render an ambiguous blank viewer surface

### Requirement: Bulk MTR Submission Workflow
The web UI SHALL provide a bulk MTR submission workflow that lets operators launch a large target set from one selected agent.

#### Scenario: Operator launches a bulk MTR job
- **WHEN** the operator opens MTR diagnostics and submits a large target list with a selected source agent
- **THEN** the UI creates one bulk MTR job
- **AND** the UI shows the new job in the diagnostics view with aggregate counts and lifecycle status

### Requirement: Bulk MTR Job Progress View
The web UI SHALL expose bulk MTR job progress with explicit queued, running, completed, failed, canceled, and total target counts plus per-target drill-down.

#### Scenario: Operator monitors a running bulk job
- **WHEN** a bulk MTR job is draining on an agent
- **THEN** the diagnostics UI updates aggregate counts and job status as target states change
- **AND** the operator can inspect individual target outcomes from the same workflow

### Requirement: Terminal Bulk Jobs Render As Terminal
The web UI SHALL render bulk MTR jobs according to their terminal state and SHALL NOT continue offering active-job controls after the job is terminal.

#### Scenario: Failed job no longer shows active actions
- **WHEN** a bulk MTR job reaches a failed or otherwise terminal outcome
- **THEN** the UI renders the job as terminal
- **AND** active-only actions such as cancel are no longer shown

### Requirement: Recurring Bulk MTR Interval Guidance
The web UI SHALL warn operators when a configured recurring bulk MTR cadence is tighter than measured execution time or recommended minimum interval.

#### Scenario: Operator configures an interval that is too aggressive
- **WHEN** a recurring bulk MTR configuration uses an interval shorter than the measured first-run baseline or recommended minimum
- **THEN** the UI warns that overlap or backlog is likely
- **AND** the UI presents the measured baseline and recommended interval

### Requirement: Analytics page hides SRQL search input
The web-ng analytics page SHALL not render the SRQL search input in the top navigation.

#### Scenario: Analytics page header
- **GIVEN** an authenticated user viewing the analytics page
- **WHEN** the page renders
- **THEN** the top navigation does not show the SRQL search input

### Requirement: Deterministic Topology Coordinate Stability
The topology UI pipeline SHALL preserve node coordinates across updates that do not change topology revision.

#### Scenario: Overlay-only update keeps coordinates stable
- **GIVEN** topology revision is unchanged
- **WHEN** a new overlay/classification update is applied
- **THEN** node coordinates SHALL remain stable
- **AND** only visual state layers SHALL change

### Requirement: Infrastructure-Anchored Layered Layout
The topology UI layout pipeline SHALL use deterministic infrastructure-aware anchoring and layered placement instead of degree-only concentric-ring placement for high-fanout topologies.

#### Scenario: High-fanout topology avoids single-ring hairball
- **GIVEN** a topology where one infrastructure node has high endpoint fanout
- **WHEN** coordinates are computed
- **THEN** infrastructure/root tiers SHALL be placed in deterministic anchor layers
- **AND** endpoints SHALL be distributed in lower layers instead of a single dense ring around one root

#### Scenario: Deterministic anchor selection
- **GIVEN** identical topology structure and node role/weight inputs
- **WHEN** layout is computed multiple times
- **THEN** anchor selection SHALL be identical across runs
- **AND** resulting coordinates SHALL remain deterministic

### Requirement: Bounded Layout Computation Budget
Topology layout recomputation SHALL run within bounded compute budgets and SHALL avoid unnecessary full-layout work for non-structural updates.

#### Scenario: Non-structural update avoids full recompute
- **GIVEN** an update changes only non-structural state
- **WHEN** the topology pipeline processes the update
- **THEN** the system SHALL skip full layout recomputation
- **AND** remain within configured latency budgets

#### Scenario: Layout hot path avoids unnecessary heavy graph analytics
- **GIVEN** a standard binary-link topology snapshot
- **WHEN** layout coordinates are computed
- **THEN** coordinate placement SHALL NOT depend on per-snapshot betweenness centrality computation
- **AND** SHALL use the optimized primary geometry path defined for binary topology links

### Requirement: Typed Telemetry Fast Path for Snapshot Encoding
The topology snapshot encoding pipeline SHALL consume typed telemetry values and SHALL NOT use per-edge JSON parsing fallback in the runtime hot path.

#### Scenario: Typed edge telemetry is mandatory in runtime hot path
- **GIVEN** edge telemetry includes typed numeric `flow_pps`, `flow_bps`, and `capacity_bps` values
- **WHEN** snapshot encoding runs
- **THEN** the encoder SHALL use typed numeric fields as the source of truth
- **AND** the runtime hot path SHALL NOT parse JSON metadata to derive telemetry values

### Requirement: Dedicated NetFlow Visualize Page
The system SHALL provide a dedicated `/netflow` route in `web-ng` for NetFlow analytics with a two-panel layout: a left options panel and a right visualization panel.

#### Scenario: User navigates to the NetFlow Visualize page
- **WHEN** a user navigates to `/netflow`
- **THEN** the page renders the left options panel and right visualization surface

### Requirement: Legacy Entry Points Redirect
The system SHALL preserve NetFlow bookmarks by redirecting legacy entry points to `/netflow` while preserving the SRQL query parameter `q` when present.

#### Scenario: Observability netflows tab redirects to /netflow
- **GIVEN** a user opens `/observability?tab=netflows&q=in:flows+time:last_1h`
- **WHEN** the route is handled
- **THEN** the user is redirected to `/netflow?q=in:flows+time:last_1h`

#### Scenario: /netflows redirects to /netflow
- **WHEN** a user opens `/netflows?q=in:flows+time:last_1h`
- **THEN** the user is redirected to `/netflow?q=in:flows+time:last_1h`

### Requirement: Shareable URL State For Visualize Options
The system SHALL encode Visualize page options into the URL as a versioned, compressed payload.

#### Scenario: URL state round-trip
- **GIVEN** the URL contains `nf=v1-<payload>`
- **WHEN** the Visualize page loads
- **THEN** the Visualize page uses the decoded options to render
- **AND** encoding the options produces the same `nf` value (deterministic)

### Requirement: NetFlow Visualize dimension picker includes exporter/interface dimensions

The NetFlow Visualize dimension picker SHALL include exporter and interface metadata dimensions when available from SRQL.

#### Scenario: User selects an interface dimension
- **GIVEN** the user is on `/netflow`
- **WHEN** they add `in_if_name` to the dimensions list
- **THEN** the selected chart uses SRQL series/group-by based on `in_if_name`

### Requirement: Dimension Selector For NetFlow Visualize
The system SHALL allow selecting and ordering dimensions for `/netflow` Visualize.

#### Scenario: User selects dimensions
- **WHEN** a user selects dimensions (e.g. `protocol_group`, `dst_port`)
- **THEN** the chart groups by the selected dimension(s) according to the chart type

### Requirement: Ranking Mode For Top-N Series
The system SHALL support ranking modes for selecting top-N series: `avg`, `max`, and `last`.

#### Scenario: User switches ranking mode
- **GIVEN** a time-series chart with multiple series
- **WHEN** the user changes ranking mode from `avg` to `max`
- **THEN** the top-N series selection updates accordingly

### Requirement: IP Truncation Control
The system SHALL support IP truncation controls for IP dimensions.

#### Scenario: User truncates source IPs
- **WHEN** a user selects `src_ip` and sets truncation to `/24`
- **THEN** the visualization groups source addresses by their `/24` CIDR prefix

### Requirement: MTR Diagnostics Page
The web UI SHALL provide a dedicated MTR diagnostics page at `/diagnostics/mtr` listing recent traces with drill-down to hop-by-hop detail, path comparison, and on-demand trace execution.

#### Scenario: Operator views MTR diagnostics
- **WHEN** the operator navigates to `/diagnostics/mtr`
- **THEN** a table of recent MTR traces is displayed with target, source agent, hop count, reachability, and timestamp
- **AND** the operator can filter by target, agent, and time range
- **AND** selecting a trace shows hop-by-hop detail with latency, loss, ASN, MPLS labels

### Requirement: God View MTR Overlay Layer
The God View topology visualization SHALL include an MTR path overlay layer that renders MTR-discovered network paths as animated directional edges with latency and loss visual encoding.

#### Scenario: MTR overlay toggled on
- **WHEN** the operator enables the MTR overlay in God View layer controls
- **THEN** `MTR_PATH` edges from `platform_graph` are rendered as animated directional arcs
- **AND** edge color encodes latency (green → yellow → red gradient)
- **AND** edge thickness encodes loss percentage

### Requirement: Device Detail MTR Tab
The device detail page SHALL include an MTR tab showing traces involving the device and providing on-demand trace execution.

#### Scenario: Operator views device MTR history
- **WHEN** the operator opens the MTR tab on a device detail page
- **THEN** traces where the device IP is source, target, or intermediate hop are listed
- **AND** a "Run MTR" action triggers an ad-hoc trace via ControlStream

### Requirement: Camera viewers prefer WebRTC when advertised
The UI SHALL prefer WebRTC playback for camera relay sessions when the relay advertises a WebRTC transport and the browser can use it.

#### Scenario: Browser uses WebRTC on the device page
- **GIVEN** a device detail page with an active camera relay session
- **AND** the relay session advertises WebRTC playback
- **WHEN** the browser supports the advertised WebRTC path
- **THEN** the viewer SHALL initialize using WebRTC

#### Scenario: Browser uses WebRTC in God-View
- **GIVEN** God-View opens one or more active camera relay viewers
- **AND** those relay sessions advertise WebRTC playback
- **WHEN** the browser supports the advertised WebRTC path
- **THEN** each viewer SHALL prefer WebRTC playback

### Requirement: Camera viewers surface fallback and negotiation state
The UI SHALL make WebRTC negotiation and fallback behavior explicit so operators can distinguish successful WebRTC playback, fallback to websocket playback, and viewer initialization failures.

#### Scenario: Viewer falls back from WebRTC to websocket
- **GIVEN** a relay session advertises both WebRTC and websocket playback
- **AND** WebRTC negotiation fails for the current browser or network path
- **WHEN** the viewer falls back to websocket playback
- **THEN** the UI SHALL indicate that fallback occurred
- **AND** SHALL continue to display relay session state and termination details

#### Scenario: No viewer transport can be established
- **GIVEN** a relay session is active
- **AND** neither WebRTC nor websocket playback can be established
- **WHEN** the viewer initializes
- **THEN** the UI SHALL show an explicit failure state
- **AND** SHALL NOT render an ambiguous blank viewer surface

### Requirement: Flow detail UI SHALL render persisted enrichment fields
Flow detail views in web-ng SHALL render protocol, TCP flag, service, directionality, provider-hosting context, and MAC vendor context from persisted enriched flow fields returned by SRQL/API. The UI SHALL NOT recompute these enrichments from raw protocol/port/byte/MAC fields when persisted values are present.

#### Scenario: Persisted enrichment fields drive rendering
- **GIVEN** a flow detail response includes persisted `protocol_label`, `tcp_flag_labels`, `dst_service_label`, `directionality_class`, `provider_class`, and MAC vendor labels
- **WHEN** an operator opens flow details in `/flows`
- **THEN** the UI renders those persisted fields directly
- **AND** does not invoke fallback runtime mapping for those attributes

#### Scenario: Device drill-in uses same persisted enrichment values
- **GIVEN** the same flow is opened from device details drill-in
- **WHEN** flow details render
- **THEN** protocol/service/tcp-flag/direction/provider/MAC-vendor labels match `/flows` exactly

### Requirement: Flow detail UI SHALL expose enrichment provenance
The flow detail UI SHALL display enrichment provenance metadata where available so operators can distinguish authoritative mappings from heuristic or unknown results.

#### Scenario: Authoritative provider mapping shown
- **GIVEN** a flow detail includes `provider_class = hosting` and `provider_source = cloud_provider_db`
- **WHEN** the operator views flow details
- **THEN** the UI displays hosting/provider context
- **AND** indicates the source as dataset-driven

#### Scenario: Unknown mapping shown explicitly
- **GIVEN** a flow detail includes unknown service or provider mapping
- **WHEN** flow details render
- **THEN** the UI shows an explicit unknown state
- **AND** raw values (such as destination port and protocol number) remain visible

#### Scenario: OUI-driven MAC vendor mapping shown
- **GIVEN** a flow detail includes source or destination MAC vendor labels with `vendor_source = ieee_oui`
- **WHEN** the operator views endpoint details
- **THEN** the UI displays MAC vendor names for available endpoints
- **AND** indicates that vendor attribution came from the IEEE OUI dataset

### Requirement: Device Detail Delete Action
The web-ng UI SHALL provide a delete action on the device detail page for admin and operator roles, with confirmation.

#### Scenario: Delete device from detail page
- **GIVEN** an admin or operator views a device detail page
- **WHEN** they click Delete and confirm
- **THEN** the device SHALL be soft deleted
- **AND** the UI SHALL navigate away or show a deleted state

### Requirement: Device Restore Action
The web-ng UI SHALL provide a restore action for deleted devices on the device detail page.

#### Scenario: Restore device from detail page
- **GIVEN** an admin or operator views a deleted device detail page
- **WHEN** they click Restore and confirm
- **THEN** the device SHALL be restored
- **AND** the UI SHALL return to the active device state

### Requirement: Show Deleted Devices Toggle
The web-ng UI SHALL provide an option to show deleted devices in the inventory list.

#### Scenario: Toggle shows deleted devices
- **GIVEN** the inventory list page
- **WHEN** the user enables “Show deleted devices”
- **THEN** tombstoned devices SHALL be included in the list
- **AND** deleted rows SHALL display a visual deleted indicator

### Requirement: Inventory Cleanup Settings
The web-ng UI SHALL expose a Network settings tab for inventory cleanup and device retention.

#### Scenario: Configure retention window
- **GIVEN** an admin user on Settings → Network
- **WHEN** they open the Inventory Cleanup tab
- **THEN** they can set the device deletion retention window in days
- **AND** the value is saved for the reaper job

#### Scenario: Configure reaper schedule
- **GIVEN** an admin user on Settings → Network
- **WHEN** they update the cleanup schedule
- **THEN** the reaper job SHALL use the configured schedule

#### Scenario: Run cleanup manually
- **GIVEN** an admin user on Settings → Network
- **WHEN** they click “Run cleanup now”
- **THEN** the reaper job SHALL execute immediately

### Requirement: Device Enrichment Rules Management UI
The web-ng Settings UI SHALL provide a Device Enrichment Rules management surface for operators.

#### Scenario: List effective rules
- **WHEN** an authorized operator navigates to Settings -> Inventory -> Device Enrichment Rules
- **THEN** the UI SHALL display effective rules with source (`builtin` or `filesystem`), enabled state, and priority

#### Scenario: Create and save a custom rule
- **WHEN** an authorized operator creates a new rule with match conditions and output mappings
- **THEN** the backend SHALL validate the rule schema
- **AND** on success the rule SHALL be persisted to the configured rules path

#### Scenario: Validation failure blocks save
- **WHEN** an operator attempts to save an invalid rule
- **THEN** the UI SHALL show structured validation errors
- **AND** the rule SHALL NOT be activated

### Requirement: Rule Simulation and Preview
The UI SHALL support simulation of enrichment rules against sample payload input before activation.

#### Scenario: Preview winning rule for sample payload
- **WHEN** an operator submits a sample payload containing SNMP metadata fields
- **THEN** the UI SHALL display the winning rule, resulting vendor/type outputs, and confidence/reason

#### Scenario: No-match preview
- **WHEN** a sample payload matches no enabled rule
- **THEN** the UI SHALL display fallback behavior and indicate no winning rule

### Requirement: Rule Import and Export
The UI SHALL support import and export of enrichment rules as YAML.

#### Scenario: Export current rules
- **WHEN** an operator exports rules
- **THEN** the system SHALL provide YAML representing the active effective rule set

#### Scenario: Import rule bundle
- **WHEN** an operator imports a YAML bundle
- **THEN** the system SHALL validate all rules before applying any change
- **AND** on success SHALL update the managed filesystem rules set

### Requirement: God-View camera nodes can open live viewers
The God-View topology experience SHALL allow operators to open a live viewer from a camera-capable endpoint node when camera stream inventory is available.

#### Scenario: Open live viewer from one camera node
- **GIVEN** the topology payload includes an endpoint node with camera stream metadata
- **WHEN** an operator selects that node and requests live view
- **THEN** the UI SHALL request an authorized relay session for that camera
- **AND** SHALL render the returned live viewer surface inline or in the associated camera panel

### Requirement: Camera cluster selection opens a tiled viewer
The God-View topology experience SHALL support opening a bounded tiled viewer for a selected cluster or set of camera-capable nodes.

#### Scenario: Open multiple camera tiles from a selection
- **GIVEN** an operator selects multiple camera-capable nodes in the topology view
- **WHEN** they request live view for the selection
- **THEN** the UI SHALL open a tiled viewer grid for the selected cameras
- **AND** SHALL cap or defer additional tiles beyond the supported live-view limit

### Requirement: Viewer errors are operator-visible
The UI SHALL distinguish unavailable camera streams from loading states so operators can tell whether a stream is still connecting, requires credentials, or failed to start.

#### Scenario: Relay session fails for one camera tile
- **GIVEN** a tiled viewer containing multiple selected cameras
- **WHEN** one relay session fails to start
- **THEN** the failed tile SHALL show an explicit unavailable or error state
- **AND** other healthy tiles SHALL continue rendering

