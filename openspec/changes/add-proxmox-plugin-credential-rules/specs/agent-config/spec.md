## ADDED Requirements

### Requirement: Credential-scoped plugin config delivery
The agent configuration pipeline SHALL deliver credential-scoped plugin assignments only to agents authorized by the credential rule scope and SHALL use broker grants instead of decrypted credential material.

#### Scenario: Agent receives scoped Proxmox assignment
- **GIVEN** a Proxmox credential rule matches devices assigned to an edge agent
- **WHEN** the agent fetches plugin configuration
- **THEN** the response SHALL include the Proxmox plugin assignment, concrete target batch, approved HTTP allowlist, and scoped credential broker grants
- **AND** assignments for other agents or edge sites SHALL NOT be included
- **AND** decrypted credential material SHALL NOT be included in the config response

#### Scenario: Sensitive fields are redacted from config diagnostics
- **GIVEN** plugin configuration includes credential-scoped assignment data
- **WHEN** config is logged, inspected through admin UI, or included in error diagnostics
- **THEN** token secrets, passwords, tickets, cookies, and CSRF tokens SHALL be redacted

### Requirement: Credential-scoped config invalidation
The system SHALL invalidate affected agent plugin configuration when credential rules, target queries, or matched device membership change.

#### Scenario: Credential rule rotation updates config version
- **GIVEN** an admin rotates the token secret for a Proxmox credential rule
- **WHEN** the change is saved
- **THEN** affected agents' plugin config versions SHALL change
- **AND** unaffected agents SHALL NOT receive a config change solely due to a rule outside their scope

### Requirement: Console session requests are edge-scoped
The agent/gateway configuration and command path SHALL allow console session requests only for targets and credentials authorized for that edge agent.

#### Scenario: Agent receives console session request
- **GIVEN** web-ng has authorized a Proxmox console session for a device assigned to an edge agent
- **WHEN** the console broker request is sent to the agent or gateway
- **THEN** the request SHALL include session ID, target endpoint, console mode, terminal dimensions, and scoped credential reference/material
- **AND** it SHALL NOT include unrelated credential rules or targets

#### Scenario: Wrong agent rejects console request
- **GIVEN** a console session request is sent to an agent outside the credential rule scope
- **WHEN** the agent validates the request
- **THEN** the agent SHALL reject the request
- **AND** web-ng SHALL close the session with an authorization failure
