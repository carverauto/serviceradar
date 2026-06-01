## ADDED Requirements

### Requirement: Bumblebee Exposure Scanner Delivered As A Native Add-on

The system SHALL deliver, govern, and supervise the Bumblebee exposure scanner as a signed
native add-on (`delivery: pushed-artifact` with an `os-package` fallback, `supervision:
systemd-timer`) rather than a standalone out-of-band package. The privileged install steps
(staging the signed scanner under the versioned `current` layout, installing/enabling the
systemd service and timer, and setting spool-directory permissions) SHALL be performed by
the root-owned `agent-updater`, and the `serviceradar-agent` SHALL remain non-root. The
scanner's runtime behavior — root-owned full-system scan, sanitized spool contract, and
partial-coverage reporting — is unchanged from the existing Bumblebee capability; this
requirement supersedes the ad-hoc standalone-package install path.

#### Scenario: Operator enables Bumblebee from Edge Ops

- **GIVEN** a `serviceradar-agent` whose build includes the native add-on manager
- **AND** an approved Bumblebee `AddonPackage`
- **WHEN** an operator assigns the Bumblebee add-on to the agent (or its cohort) in Edge Ops
- **THEN** the signed Bumblebee artifact SHALL be delivered and activated via the root-owned `agent-updater`
- **AND** the systemd service and timer SHALL be installed and enabled with correct spool-directory permissions
- **AND** the non-root agent SHALL ingest the sanitized spool and report findings without read access to arbitrary user home directories

#### Scenario: Unsigned or mis-signed artifact is rejected

- **GIVEN** a Bumblebee add-on artifact whose signature or `sha256` does not verify against the agent's trusted release key
- **WHEN** the agent attempts activation
- **THEN** activation SHALL be refused
- **AND** no Bumblebee service or timer SHALL be installed or enabled
- **AND** any previously active Bumblebee version SHALL remain current

#### Scenario: Disabling the assignment stops scanning

- **GIVEN** an agent running the Bumblebee add-on via a systemd timer
- **WHEN** the Bumblebee assignment is disabled or unassigned in Edge Ops
- **THEN** the agent SHALL stop ingesting the Bumblebee spool
- **AND** the privileged path SHALL disable the Bumblebee timer
- **AND** the agent SHALL report the Bumblebee add-on as not active

#### Scenario: Base agent package installs no scanner

- **GIVEN** an operator installs the standard `serviceradar-agent` RPM or deb
- **WHEN** the package post-install runs
- **THEN** it SHALL NOT install, enable, or start the Bumblebee scanner, service, or timer
- **AND** the Bumblebee scanner SHALL be present only after the Bumblebee add-on is delivered

#### Scenario: Failed activation rolls back without a half-installed timer

- **GIVEN** a newly delivered Bumblebee add-on version that fails verification or launch
- **WHEN** the agent attempts to activate it
- **THEN** the previously active Bumblebee version SHALL remain current
- **AND** no partially installed or enabled Bumblebee timer SHALL be left on the host

#### Scenario: Add-on state and drift are reported

- **GIVEN** a Bumblebee add-on assigned to an agent
- **WHEN** the agent reconciles the assignment
- **THEN** it SHALL report the Bumblebee add-on's installed/active/degraded state, version, and architecture through the add-on status read model
- **AND** Edge Ops SHALL surface assigned-but-not-active or arch-unsupported Bumblebee assignments as drift
