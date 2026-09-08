## ADDED Requirements

### Requirement: Pushed-artifact add-on activation and rollback
The agent SHALL activate a `pushed-artifact` add-on by staging the fetched bundle in a
versioned staged directory, verifying its `sha256` and signature, then atomically
switching a `current` symlink; on any verification or launch failure it SHALL roll back
to the previously active version and SHALL NOT serve the failed version. Required OS
file capabilities SHALL be applied via the root-owned `agent-updater`, never by the
add-on process itself.

#### Scenario: Verified bundle is activated atomically
- **GIVEN** a fetched pushed-artifact bundle whose `sha256` and signature verify
- **WHEN** the agent activates it
- **THEN** the bundle SHALL be placed in a versioned staged directory
- **AND** the `current` symlink SHALL be switched atomically to the new version

#### Scenario: Bad signature rolls back
- **GIVEN** a fetched bundle whose signature does not verify
- **WHEN** the agent attempts activation
- **THEN** activation SHALL be refused
- **AND** the previously active version SHALL remain current

#### Scenario: File capabilities applied via agent-updater
- **GIVEN** an add-on whose `requires.os_capabilities` is non-empty
- **WHEN** the agent activates it
- **THEN** the required file capabilities SHALL be applied by the root-owned `agent-updater`
- **AND** the add-on process SHALL NOT be granted the ability to set its own capabilities

### Requirement: Non-sidecar add-on supervision dispatch
The agent SHALL dispatch an enabled assignment to the supervision model declared by its
package — `config-toggle`, `agent-sidecar`, `systemd-service`, `systemd-timer`, or
`ephemeral-helper` — and SHALL report an assignment whose model it cannot run as
unsupported rather than silently ignoring it.

#### Scenario: systemd-timer add-on spools for ingest
- **GIVEN** an enabled add-on assignment with `supervision: systemd-timer`
- **WHEN** the agent applies the assignment
- **THEN** it SHALL install the timer and its unit
- **AND** the agent SHALL ingest the add-on's spooled output

#### Scenario: config-toggle add-on flips an in-agent capability
- **GIVEN** an enabled add-on assignment with `supervision: config-toggle`
- **WHEN** the agent applies the assignment
- **THEN** it SHALL enable the corresponding in-agent capability without launching a subprocess

#### Scenario: Unsupported model is surfaced
- **GIVEN** an enabled assignment whose supervision model this agent build cannot run
- **WHEN** the agent applies the assignment
- **THEN** it SHALL report the assignment as unsupported with the delivery/supervision model
- **AND** SHALL NOT report it as applied

### Requirement: Add-on assignment last-known-good cache
The agent SHALL persist the last successfully applied add-on assignment set and SHALL
fall back to it when a fresh delivery or verification fails, so a transient failure
does not drop a running add-on. A local override SHALL take precedence over the pushed
assignment, mirroring the existing agent config override/cache pattern.

#### Scenario: Delivery failure falls back to last-known-good
- **GIVEN** a previously applied add-on assignment set
- **WHEN** a fresh assignment delivery or artifact verification fails
- **THEN** the agent SHALL keep running the last-known-good assignment set
- **AND** SHALL record the delivery failure

#### Scenario: Local override wins
- **GIVEN** a local add-on assignment override on the agent host
- **WHEN** the agent reconciles assignments
- **THEN** the override SHALL take precedence over the pushed assignment
