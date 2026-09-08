## ADDED Requirements

### Requirement: Per-user timezone preference

The system SHALL persist one normalized IANA timezone identifier from the server's filtered profile catalog for each user. The preference SHALL default to `Etc/UTC`, SHALL be available through the authenticated user scope, and SHALL be writable only through a dedicated self-service action that targets the acting user's own record.

#### Scenario: Existing user receives the UTC default

- **GIVEN** a user record created before timezone preferences existed
- **WHEN** the timezone migration is applied
- **THEN** the user's timezone SHALL be `Etc/UTC`
- **AND** the user SHALL continue to authenticate without changing any existing credentials or authorization state

#### Scenario: New user receives the UTC default

- **WHEN** a user is created without an explicit timezone
- **THEN** the persisted timezone SHALL be `Etc/UTC`

#### Scenario: User saves a supported timezone

- **GIVEN** an authenticated user editing their own profile
- **WHEN** the user selects an installed IANA timezone such as `America/Chicago`
- **THEN** the system SHALL persist that exact timezone identifier
- **AND** a fresh authenticated scope SHALL expose the saved value

#### Scenario: UTC alias is normalized

- **GIVEN** an authenticated user editing their own profile
- **WHEN** the user submits an accepted UTC alias such as `UTC`, `GMT`, or `Z`
- **THEN** the system SHALL persist `Etc/UTC`
- **AND** SHALL NOT persist the alias or surrounding whitespace

#### Scenario: Unsupported timezone is rejected

- **GIVEN** an authenticated user editing their own profile
- **WHEN** the submitted timezone is blank, an abbreviation or fixed offset (including `Etc/GMT+5`), a POSIX entry, or is not present in the server's filtered profile catalog
- **THEN** the update SHALL be rejected with a field-level validation error
- **AND** the previously persisted timezone SHALL remain unchanged

#### Scenario: Product administrator cannot update another user's timezone

- **GIVEN** an authenticated administrator with `settings.auth.manage`
- **WHEN** they attempt to invoke the timezone preference action for another user
- **THEN** the system SHALL deny the update
- **AND** the target user's timezone SHALL remain unchanged

#### Scenario: Catalog failure preserves the preference

- **GIVEN** an authenticated user with a saved timezone
- **WHEN** the server cannot validate a submitted non-UTC timezone against its profile catalog
- **THEN** the update SHALL fail with a validation error
- **AND** the saved timezone SHALL remain unchanged
