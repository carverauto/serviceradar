## ADDED Requirements
### Requirement: Admin User Updates Are Atomic
The system SHALL apply admin user updates that affect role, role profile, and display name atomically so partial privilege changes cannot commit on failure.

#### Scenario: Later validation failure rolls back earlier role change
- **GIVEN** an admin update request that changes a user's role and role profile
- **AND** the requested role profile change is invalid
- **WHEN** the update is attempted
- **THEN** the overall update SHALL fail
- **AND** the earlier role change SHALL NOT remain committed

### Requirement: Admins Can Explicitly Clear Role Profiles
The system SHALL distinguish omitted role profile input from an explicit request to clear a role profile.

#### Scenario: Explicit nil clears role profile
- **GIVEN** a user currently has a role profile assigned
- **WHEN** an admin update explicitly sets `role_profile_id` to null or empty
- **THEN** the user's role profile SHALL be cleared

#### Scenario: Omitted role profile leaves existing assignment unchanged
- **GIVEN** a user currently has a role profile assigned
- **WHEN** an admin update omits `role_profile_id`
- **THEN** the existing role profile assignment SHALL remain unchanged
