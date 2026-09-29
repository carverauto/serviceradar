## ADDED Requirements

### Requirement: Authorized replay and retention
The system SHALL provide bounded timeline, seek and export operations with
resource authorization, visible gaps and a reconciled retention/hold lifecycle.

#### Scenario: Shared map or recording link
- **WHEN** a recipient opens a link naming a camera, object or recording interval
- **THEN** the host SHALL authorize access independently of the link
- **AND** the link SHALL contain no source credential or durable object-store access token
- **AND** unavailable or expired footage SHALL be identified explicitly

#### Scenario: Hold conflicts with deletion
- **WHEN** a retention deletion races a hold request
- **THEN** an atomic index transition SHALL determine which operation is accepted
- **AND** the system SHALL not confirm a hold on deleted or temporary-only media
- **AND** deletion SHALL be rechecked in object storage before marking it complete
