## ADDED Requirements
### Requirement: Action launch feedback points to results
After a northbound or plugin-backed action is launched from device or interface details, the UI SHALL explain where the result will appear and SHALL refresh the relevant Action History without blocking the launch event. Action History rows SHALL render only meaningful target/result fields and SHALL omit placeholder values such as `nil`.

#### Scenario: Device action launch succeeds
- **GIVEN** an operator launches a device action
- **WHEN** the action is accepted
- **THEN** the UI confirms the action was started
- **AND** tells the operator that progress and results are available in Action History
- **AND** the Action History section refreshes to include the invocation

#### Scenario: Action history contains optional empty field
- **GIVEN** an action result has an optional field with nil or empty value
- **WHEN** Action History renders the row
- **THEN** the empty field is omitted
- **AND** the UI does not display the literal text `nil`

### Requirement: Action launch authorization is explicit and role-consistent
Device and interface action launches SHALL authorize against `northbound.actions.launch`. Users who are expected to run actions in the demo namespace SHALL have that permission through their assigned role. Unauthorized responses SHALL identify the exact missing permission rather than returning a generic denial.

#### Scenario: Authorized demo operator launches interface action
- **GIVEN** a demo operator has `northbound.actions.launch`
- **WHEN** the operator launches an action against an interface
- **THEN** the action is accepted or returns a target/plugin-specific validation error
- **AND** the UI does not show a missing `northbound.actions.launch` denial

#### Scenario: Unauthorized user receives precise denial
- **GIVEN** a user lacks `northbound.actions.launch`
- **WHEN** the user attempts to launch a device or interface action
- **THEN** the launch is denied
- **AND** the response identifies `northbound.actions.launch` as the missing permission

### Requirement: Interface action target context is plugin-contract driven
Interface action target snapshots SHALL include normalized interface identity fields such as interface name, ifIndex, device IP, and physical/module location when available. The plugin contract SHALL declare which supported device/interface fields an action needs, and the system SHALL construct payloads from that contract rather than relying on hard-coded fields or brittle string assumptions.

#### Scenario: Interface audit includes ifIndex and name
- **GIVEN** a plugin action declares it needs `device.ip`, `interface.name`, and `interface.if_index`
- **WHEN** an operator launches the action against an interface
- **THEN** the target snapshot includes the device IP, interface name, and numeric ifIndex
- **AND** target snapshot encoding preserves numeric fields without string-unmarshal failures

#### Scenario: Modular interface includes physical context
- **GIVEN** an interface name such as `1/1/3` belongs to a chassis/module context
- **WHEN** a plugin action requests physical interface context
- **THEN** the target snapshot includes available module/slot/port fields separately from ifIndex
- **AND** ifIndex is not treated as the physical line-card port number
