## ADDED Requirements

### Requirement: Agent Applies Add-on Assignments
The `serviceradar-agent` SHALL apply delivered add-on (feature-set) assignments by
dispatching each to its declared delivery and supervision model: enabling a
compiled-in capability by configuration, fetching and verifying a pushed signed
artifact before activation, or activating an out-of-band installed package. The agent
SHALL enable, disable, and supervise add-ons independently of one another, and SHALL
gracefully stop an add-on when its assignment is removed or disabled.

#### Scenario: Agent enables a compiled-in add-on
- **GIVEN** an agent receives an assignment for a compiled-in add-on with enablement set
- **WHEN** the agent applies the configuration
- **THEN** it SHALL enable the already-present capability
- **AND** it SHALL advertise the corresponding capability as active

#### Scenario: Agent installs and supervises a pushed-artifact add-on
- **GIVEN** an agent receives an assignment for a pushed-artifact add-on for its architecture
- **WHEN** the agent applies the configuration
- **THEN** it SHALL fetch the signed artifact, verify content hash and signature, and stage it under a versioned directory
- **AND** it SHALL activate the staged artifact and supervise it per the declared supervision model
- **AND** it SHALL roll back to the prior state if verification or activation fails

#### Scenario: Agent disables an add-on cleanly
- **GIVEN** an agent running an enabled add-on
- **WHEN** the assignment is disabled or removed
- **THEN** the agent SHALL gracefully stop the add-on
- **AND** other running add-ons SHALL be unaffected

### Requirement: Add-on Assignment Override And Cache
The `serviceradar-agent` SHALL support a local filesystem override for add-on
assignments and SHALL cache the last-known-good add-on assignments so add-ons keep
operating when the control plane is unreachable.

#### Scenario: Local override takes precedence
- **GIVEN** a valid local add-on configuration override exists under the ServiceRadar configuration directory
- **WHEN** the agent resolves add-on configuration
- **THEN** the local override SHALL take precedence over remotely delivered add-on settings
- **AND** the agent SHALL log that a local add-on override is in use

#### Scenario: Cached assignment used when control plane is unreachable
- **GIVEN** an agent has cached add-on assignments and verified artifacts
- **AND** the control plane is unreachable during configuration refresh
- **WHEN** the agent restarts or refreshes
- **THEN** it SHALL continue running enabled add-ons from the last-known-good cache
- **AND** SHALL report the cached assignment identifiers in its status

### Requirement: Agent Reports Add-on State
The `serviceradar-agent` SHALL report, per add-on, whether it is installed,
available, active, or unhealthy, including a bounded degradation reason and the
add-on version, through the existing agent capability advertisement and status path.

#### Scenario: Agent reports active add-on
- **GIVEN** an agent has an enabled, healthy add-on
- **WHEN** the agent reports its capabilities and status
- **THEN** it SHALL report the add-on as active with its version

#### Scenario: Agent reports degraded add-on with reason
- **GIVEN** an enabled add-on that cannot acquire a required OS capability
- **WHEN** the agent reports its status
- **THEN** it SHALL report the add-on as unavailable or unhealthy
- **AND** it SHALL include a bounded degradation reason
