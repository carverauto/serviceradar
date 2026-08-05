## ADDED Requirements

### Requirement: Plugin secret references reuse unified credential inventory
Plugin configuration UI SHALL allow secret-reference fields to select compatible credentials from the unified credential inventory and create new compatible secrets inline when supported.

#### Scenario: Select plugin credential
- **GIVEN** a plugin schema declares a secret reference field
- **WHEN** the admin configures the plugin
- **THEN** the UI SHALL offer compatible existing credentials from the unified inventory
- **AND** it SHALL pass only secret references or broker grants to runtime configuration

#### Scenario: Create plugin credential inline
- **GIVEN** a plugin secret reference field maps to a known provider/auth preset
- **WHEN** the admin enters new secret material inline
- **THEN** the system SHALL create an encrypted credential secret
- **AND** the plugin configuration SHALL reference that secret rather than storing plaintext

### Requirement: Credential delivery mode governs assignability
A plugin SHALL declare how it receives credentials, and the system SHALL NOT offer an assignment mode that cannot deliver them. A plugin whose credentials arrive per-invocation with a command SHALL NOT be assignable on a polling interval, because a polled assignment carries no grant and can only ever fail.

This closes an observed failure: the AWX / AAP Bridge declares "holds no per-controller state; each request carries its own credential broker grant", yet the UI accepted a manual assignment with a 60-second interval. Every poll invoked the plugin with no grant and reported `api_token is required (resolved from credential broker grant)` once a minute. Three separate manual assignments had been created this way and two were silently disabled by operators before the cause was understood. The credential system was healthy throughout — the resolution audit recorded no failure at any point — so the surfaced error blamed credentials for what was an unsatisfiable assignment.

#### Scenario: Command-delivered plugin is not offered a polling assignment
- **GIVEN** an approved package declares that its credentials are delivered per-invocation with a command
- **WHEN** an admin opens the assignment form for that plugin
- **THEN** the UI SHALL NOT offer a polling interval or a manual scheduled assignment
- **AND** it SHALL state that the plugin is invoked on demand

#### Scenario: Unsatisfiable assignment is rejected rather than polled
- **WHEN** a client submits a scheduled or interval-bearing assignment for a command-delivered plugin
- **THEN** the system SHALL reject it
- **AND** it SHALL NOT create an assignment that would emit a recurring credential error

#### Scenario: Existing unsatisfiable assignments are reported
- **GIVEN** an enabled assignment exists that its plugin's delivery mode cannot satisfy
- **WHEN** the plugin or assignment inventory is reviewed
- **THEN** the system SHALL identify that assignment as unsatisfiable and name the reason
- **AND** it SHALL NOT report the condition as a credential resolution failure
