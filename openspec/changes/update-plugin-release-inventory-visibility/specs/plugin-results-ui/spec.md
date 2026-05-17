## ADDED Requirements
### Requirement: Task launch feedback points to results
After a northbound or plugin-backed task is launched from device or interface details, the UI SHALL explain where the result will appear and SHALL refresh the relevant task history without blocking the launch event. Task history rows SHALL render only meaningful target/result fields and SHALL omit placeholder values such as `nil`.

#### Scenario: Device task launch succeeds
- **GIVEN** an operator launches a device task
- **WHEN** the task is accepted
- **THEN** the UI confirms the task was started
- **AND** tells the operator that progress and results are available in Task History
- **AND** the Task History section refreshes to include the invocation

#### Scenario: Task history contains optional empty field
- **GIVEN** a task result has an optional field with nil or empty value
- **WHEN** Task History renders the row
- **THEN** the empty field is omitted
- **AND** the UI does not display the literal text `nil`

### Requirement: Task launch authorization is explicit and role-consistent
Device and interface task launch actions SHALL authorize against the documented northbound action permission for the deployment. Users who are expected to run tasks in the demo namespace SHALL have that permission through their assigned role. Unauthorized responses SHALL identify the missing permission rather than returning a generic denial.

#### Scenario: Authorized demo operator launches interface task
- **GIVEN** a demo operator has the northbound task launch permission
- **WHEN** the operator launches a task against an interface
- **THEN** the task is accepted or returns a target/plugin-specific validation error
- **AND** the UI does not show "You are not authorized to launch tasks"

#### Scenario: Unauthorized user receives precise denial
- **GIVEN** a user lacks the northbound task launch permission
- **WHEN** the user attempts to launch a device or interface task
- **THEN** the launch is denied
- **AND** the response identifies the missing task-launch permission

### Requirement: Interface task target context is plugin-contract driven
Interface task target snapshots SHALL include normalized interface identity fields such as interface name, ifIndex, device IP, and physical/module location when available. The plugin contract SHALL declare which supported device/interface fields an action needs, and the system SHALL construct payloads from that contract rather than relying on hard-coded fields or brittle string assumptions.

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
