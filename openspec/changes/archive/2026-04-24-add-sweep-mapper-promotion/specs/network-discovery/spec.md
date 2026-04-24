## ADDED Requirements
### Requirement: Mapper Discovery Accepts Sweep-Promoted Targets
The system SHALL support on-demand mapper discovery for sweep-promoted hosts by reusing existing mapper job assignment and command-bus delivery.

#### Scenario: Promote live host through an eligible mapper job
- **GIVEN** a live sweep-discovered host is eligible for mapper promotion
- **AND** a mapper job exists in the same partition and compatible agent scope
- **WHEN** the promotion is dispatched
- **THEN** the system SHALL trigger mapper discovery through that mapper job's assigned agent context
- **AND** the promoted host SHALL be included as a discovery target for the on-demand run

#### Scenario: Agent-specific mapper job is preferred
- **GIVEN** multiple mapper jobs could accept a promoted host
- **AND** one of them is assigned to the same agent that executed the sweep
- **WHEN** the system selects a mapper job for promotion
- **THEN** the system SHALL prefer the agent-specific mapper job over a less-specific fallback

### Requirement: Mapper Promotion Dispatch Is Idempotent
The system SHALL avoid duplicate mapper discovery dispatches for the same promoted host within the configured suppression window.

#### Scenario: Repeated sweep hits do not spam mapper runs
- **GIVEN** a live host has already triggered mapper promotion recently
- **WHEN** subsequent sweep results ingest the same host before the suppression window expires
- **THEN** the system SHALL NOT dispatch another mapper promotion for that host
- **AND** the existing mapper job queue SHALL remain bounded

#### Scenario: Host can be promoted again after suppression window
- **GIVEN** a live host was previously promoted
- **WHEN** the suppression window has expired and the host is seen again by sweep
- **THEN** the system SHALL allow a new mapper promotion dispatch
