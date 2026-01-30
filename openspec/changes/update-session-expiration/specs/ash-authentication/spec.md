## MODIFIED Requirements
### Requirement: Session Management
The system SHALL manage user sessions with configurable idle and absolute expiration (default idle timeout 1 hour), refresh behavior, and logout capabilities.

#### Scenario: Session idle expiration
- **GIVEN** a user session with no authenticated activity for longer than the configured idle timeout
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Session refresh on any authenticated request
- **GIVEN** a user session that is within the configured idle timeout and below the absolute expiration
- **WHEN** the user makes any authenticated request
- **THEN** the system SHALL refresh the session expiration window
- **AND** preserve the authenticated session without forcing re-login

#### Scenario: Session absolute expiration
- **GIVEN** a user session older than the configured absolute lifetime (default 30 days)
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Logout
- **WHEN** a user logs out
- **THEN** the system SHALL invalidate the current session token
- **AND** remove the session cookie
