## ADDED Requirements
### Requirement: Boombox-backed analysis remains relay-attached
The system SHALL allow a Boombox-backed analysis adapter to consume relay-derived analysis media without requiring another upstream camera pull or direct worker access to edge cameras.

#### Scenario: Relay-derived media is bridged through Boombox
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform enables a Boombox-backed analysis adapter for that branch
- **THEN** the adapter SHALL consume media from the platform relay branch
- **AND** SHALL NOT require a direct session to the edge agent or customer camera

### Requirement: Boombox analysis remains optional
The system SHALL treat Boombox as an optional analysis adapter and SHALL NOT require it for all analysis paths.

#### Scenario: Deployment uses another analysis adapter
- **GIVEN** a deployment that uses the existing HTTP analysis adapter
- **WHEN** Boombox is not enabled
- **THEN** the platform SHALL continue to support bounded analysis dispatch without Boombox
