## ADDED Requirements

### Requirement: Crash-free assignment deletion
The plugin configuration UI SHALL handle successful assignment deletion without crashing regardless of whether the underlying delete operation returns a deleted assignment or a bare success value.

#### Scenario: Delete returns bare success
- **GIVEN** an operator has permission to assign plugins
- **AND** an existing plugin assignment is visible in the package details view
- **WHEN** the operator removes the assignment and the delete operation returns `:ok`
- **THEN** the LiveView remains mounted
- **AND** the assignment list refreshes without the removed assignment
- **AND** the UI shows a success message

#### Scenario: Delete returns deleted assignment
- **GIVEN** an operator has permission to assign plugins
- **AND** an existing plugin assignment is visible in the package details view
- **WHEN** the operator removes the assignment and the delete operation returns the deleted assignment
- **THEN** the LiveView remains mounted
- **AND** the assignment list refreshes without the removed assignment
- **AND** the UI shows a success message

### Requirement: Assignment upgrade actions
The plugin configuration UI SHALL show an upgrade action next to an existing assignment when a newer approved package version exists for the same logical plugin.

#### Scenario: Newer approved version is available
- **GIVEN** an agent has an enabled assignment to plugin `p` version `1.0.0`
- **AND** plugin `p` version `1.1.0` is approved
- **WHEN** the operator views assignments for plugin `p`
- **THEN** the assignment row shows the current version
- **AND** the row offers an action to upgrade to the latest approved version

#### Scenario: Assignment already uses latest version
- **GIVEN** an agent has an enabled assignment to plugin `p` version `1.1.0`
- **AND** no newer approved package for plugin `p` exists
- **WHEN** the operator views assignments for plugin `p`
- **THEN** the row identifies the assignment as current
- **AND** the row does not show an upgrade action

### Requirement: Specific-version assignment upgrade
The plugin configuration UI SHALL allow an operator to upgrade or move an assignment to a selected approved package version for the same logical plugin.

#### Scenario: Operator selects a target version
- **GIVEN** an agent has an enabled assignment to plugin `p`
- **AND** plugin `p` has multiple approved package versions
- **WHEN** the operator selects version `1.1.0` and confirms the upgrade
- **THEN** the assignment points at the package for plugin `p` version `1.1.0`
- **AND** compatible assignment configuration, interval, timeout, permissions override, and resources override are preserved

#### Scenario: Target version requires incompatible configuration
- **GIVEN** an agent has an enabled assignment to plugin `p`
- **AND** the selected target package has required configuration fields that are missing from the current assignment params
- **WHEN** the operator confirms the upgrade
- **THEN** the assignment is not changed
- **AND** the UI shows an actionable validation message

### Requirement: Duplicate assignment guidance
The plugin configuration UI SHALL guide users to upgrade or replace an existing assignment when assignment creation fails because the agent already has an enabled assignment for the same logical plugin.

#### Scenario: Duplicate manual assignment is attempted
- **GIVEN** an agent already has an enabled assignment for plugin `p`
- **WHEN** the operator tries to assign another approved package for plugin `p` to the same agent
- **THEN** the UI does not present the failure as an unexpected error
- **AND** the UI explains that the plugin is already enabled on that agent
- **AND** the UI offers the upgrade or replacement path when available

### Requirement: Policy-owned assignment protection
The plugin configuration UI SHALL prevent manual package-version upgrades of policy-owned assignments unless policy semantics explicitly allow that operation.

#### Scenario: Policy-owned assignment has newer package
- **GIVEN** an agent has a policy-owned assignment for plugin `p`
- **AND** plugin `p` has a newer approved package version
- **WHEN** the operator views the assignment in the package UI
- **THEN** manual upgrade controls are disabled or hidden
- **AND** the UI indicates that the assignment is managed by policy
