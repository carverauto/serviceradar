## MODIFIED Requirements
### Requirement: Discovery job assignment uses registered agents
Discovery job assignment SHALL be selected from the registry of known agents in the selected partition, and the API MUST reject assignments to unknown agent IDs.

#### Scenario: Assign job to a known agent
- **GIVEN** an admin opens the discovery job editor
- **WHEN** they open the agent assignment selector
- **THEN** the UI lists registered agent IDs for the partition
- **AND** selecting an agent allows the job to save

#### Scenario: Reject unknown agent assignment
- **GIVEN** an admin submits a discovery job with an agent ID that does not exist
- **WHEN** the job is saved
- **THEN** the API returns a validation error
- **AND** the job is not scheduled for execution

## ADDED Requirements
### Requirement: On-demand discovery via command bus
The system SHALL allow admins to trigger a discovery job immediately via the command bus when the assigned agent is online.

#### Scenario: Run discovery job now
- **GIVEN** a discovery job assigned to an online agent
- **WHEN** the admin selects "Run now"
- **THEN** the system sends a discovery command over the control stream
- **AND** the UI receives command status updates

#### Scenario: Run discovery job while agent offline
- **GIVEN** a discovery job assigned to an offline agent
- **WHEN** the admin selects "Run now"
- **THEN** the system returns an immediate error
