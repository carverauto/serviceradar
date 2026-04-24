## MODIFIED Requirements
### Requirement: Session Management
The system SHALL manage user sessions with configurable expiration and logout capabilities.

Revoked session and refresh tokens SHALL remain revoked across application restarts until their revocation window expires.

#### Scenario: Session expiration
- **GIVEN** a user session older than 30 days
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Logout
- **WHEN** a user logs out
- **THEN** the system SHALL invalidate the current session token
- **AND** remove the session cookie

#### Scenario: Revoked token remains invalid after restart
- **GIVEN** a token has been revoked before its natural expiration
- **WHEN** `web-ng` restarts
- **THEN** the token SHALL still be rejected
- **AND** the revocation state SHALL remain effective until its expiration window ends

## ADDED Requirements
### Requirement: Trusted Proxy Client IP Resolution
The system SHALL derive client IP addresses from proxy headers only when the immediate peer is a configured trusted proxy, and SHALL ignore attacker-controlled forwarded hops.

#### Scenario: Ignore spoofed leftmost forwarded address
- **GIVEN** `X-Forwarded-For` trust is enabled
- **AND** the request arrives through a configured trusted proxy
- **WHEN** the forwarded chain contains an attacker-controlled leftmost hop and a real client IP behind it
- **THEN** the system SHALL resolve the client IP from the rightmost untrusted hop
- **AND** SHALL NOT trust the attacker-controlled leftmost value

#### Scenario: Ignore forwarded headers from untrusted peers
- **GIVEN** `X-Forwarded-For` trust is enabled
- **WHEN** a request arrives directly from an untrusted peer with a forged `X-Forwarded-For` header
- **THEN** the system SHALL use the socket `remote_ip`
- **AND** SHALL ignore the forwarded header
