## MODIFIED Requirements

### Requirement: Settings Navigation Structure
The Settings UI SHALL organize configuration options into logical sections with consistent navigation. The sidebar SHALL remain visible on all settings pages.

#### Scenario: Network section contains network-related settings
- **WHEN** user navigates to Settings
- **THEN** the sidebar displays a "Network" section (not "Networks")
- **AND** SNMP settings are accessible under the Network section

#### Scenario: Agents section contains agent-related settings
- **WHEN** user navigates to Settings
- **THEN** the sidebar displays an "Agents" section
- **AND** Sysmon settings are accessible under the Agents section
- **AND** a "Deploy New Agent" action is available

#### Scenario: Navigation elements persist on all settings pages
- **WHEN** user navigates to any settings page (SNMP, Sysmon, etc.)
- **THEN** the topbar and sidebar remain visible
- **AND** the user can navigate to other sections without page reload

## ADDED Requirements

### Requirement: SNMP Credentials Management
The SNMP settings page SHALL provide forms for configuring SNMP authentication credentials.

#### Scenario: Configure SNMPv2c community string
- **WHEN** user creates or edits an SNMP configuration
- **THEN** the form displays a field for community string
- **AND** the community string is stored securely

#### Scenario: Configure SNMPv3 authentication
- **WHEN** user selects SNMPv3 as the SNMP version
- **THEN** the form displays fields for username, auth protocol, auth password, privacy protocol, and privacy password
- **AND** the credentials are validated before saving

### Requirement: Edge Ops Simplified Onboarding
Edge Ops SHALL provide exactly two onboarding workflows: one for NATS leaf servers and one for agents.

#### Scenario: NATS leaf server onboarding
- **WHEN** user accesses Edge Ops in Settings
- **THEN** a single clear action for "Onboard NATS Leaf Server" is displayed
- **AND** the onboarding wizard guides through leaf server setup

#### Scenario: Agent onboarding separated from Edge Ops
- **WHEN** user wants to deploy a new agent
- **THEN** the agent onboarding is accessed via the Agents section
- **AND** Edge Ops does not duplicate agent onboarding functionality

### Requirement: Device Import from CSV
The Devices view SHALL allow bulk import of devices from CSV/spreadsheet files.

#### Scenario: Import devices via CSV
- **WHEN** user clicks "Import Devices" button
- **THEN** a modal displays with file upload and template download options
- **AND** the CSV columns map to ocsf_devices schema fields
- **AND** imported devices are created without user-supplied UUIDs (system-generated)

#### Scenario: Download import template
- **WHEN** user clicks "Download Template" in the import modal
- **THEN** a CSV template with correct column headers is downloaded
- **AND** the template includes example data and column descriptions

### Requirement: Device Details Editing
The Device Details page SHALL allow authorized users to edit device information.

#### Scenario: Edit device details with RBAC
- **WHEN** user with admin or edit permission views device details
- **THEN** an "Edit" button is displayed
- **AND** clicking Edit makes form fields editable
- **AND** changes are debounced to prevent excessive API calls

#### Scenario: View-only for unauthorized users
- **WHEN** user without edit permission views device details
- **THEN** the "Edit" button is not displayed
- **AND** all fields are read-only

### Requirement: Device Pagination with Total Count
The Devices table pagination SHALL display both current page count and total device count.

#### Scenario: Display total count in pagination
- **WHEN** user views the devices table
- **THEN** pagination shows format "Showing X of Y devices"
- **AND** page number controls allow direct page navigation (not just prev/next arrows)

### Requirement: Integration Source Dynamic Forms
Integration source creation forms SHALL display fields appropriate to the selected integration type.

#### Scenario: Armis integration shows API credential fields
- **WHEN** user selects "Armis" as integration source type
- **THEN** form displays structured fields for API key and API secret
- **AND** freetext JSON input is not required

#### Scenario: Netbox integration shows API credential fields
- **WHEN** user selects "Netbox" as integration source type
- **THEN** form displays fields for Netbox URL and API token

#### Scenario: Network blacklist conditional display
- **WHEN** user selects an integration type that supports blacklisting
- **THEN** the network blacklist field is displayed
- **WHEN** user selects an integration type that does not support blacklisting
- **THEN** the network blacklist field is hidden

### Requirement: Form Input Validation Fixes
All settings forms SHALL correctly capture and validate user input.

#### Scenario: Sysmon profile processes selection
- **WHEN** user creates a Sysmon profile and selects "Processes" monitoring
- **THEN** the form does not erroneously require mount points
- **AND** the profile saves successfully with process monitoring enabled

#### Scenario: Network sweep ports input
- **WHEN** user enters comma-separated ports in the network sweep profile form
- **THEN** the input is correctly captured and stored
- **AND** validation accepts standard port formats (e.g., "22,80,443,8080")
