## ADDED Requirements
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

### Requirement: Discovery job run diagnostics
The system SHALL persist and expose discovery job run diagnostics including last run timestamp, status, interface count, and error summary.

#### Scenario: Successful discovery run reports diagnostics
- **GIVEN** a discovery job completes successfully
- **WHEN** the discovery job list is loaded
- **THEN** the response includes last run timestamp, status set to success, and a non-zero interface count

#### Scenario: Failed discovery run reports diagnostics
- **GIVEN** a discovery job fails to execute or returns no interfaces
- **WHEN** the discovery job list is loaded
- **THEN** the response includes last run timestamp, status set to error, and an error summary

### Requirement: Discovery jobs can be triggered on demand
The system SHALL allow admins to trigger a discovery job immediately from the discovery jobs list.

#### Scenario: Run discovery job now
- **GIVEN** a discovery job is configured
- **WHEN** the admin selects "Run now" in the discovery jobs list
- **THEN** the job is queued to execute immediately on the assigned agent or partition
