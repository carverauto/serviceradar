## MODIFIED Requirements
### Requirement: Sysmon settings UI
The UI SHALL allow admins to configure sysmon profiles.

#### Scenario: Configure disk collection
- **WHEN** an admin edits a sysmon profile
- **THEN** they can enable disk collection
- **AND** they can choose whether to collect all disks or specify a list of disk paths

#### Scenario: Configure disk excludes
- **WHEN** an admin edits a sysmon profile
- **THEN** they can specify disk exclusion paths to omit mounts from collection
- **AND** the UI SHALL describe that an empty include list means "collect all"
