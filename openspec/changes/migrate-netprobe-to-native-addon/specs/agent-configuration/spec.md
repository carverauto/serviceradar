## ADDED Requirements

### Requirement: Netprobe Host-Network-Visibility Sidecar Delivered As A Native Add-on

The system SHALL deliver, govern, and supervise the netprobe host-network-visibility sidecar as a
signed native add-on (`delivery: pushed-artifact` with an `os-package` fallback, `supervision:
systemd-service`) rather than as a binary baked into the base `serviceradar-agent` package. The
privileged install steps (staging the signed binary under the versioned `current` layout, applying
the required file capabilities `CAP_NET_RAW` / `CAP_BPF` / `CAP_PERFMON` via `setcap`, and
installing/enabling the systemd service) SHALL be performed by the root-owned `agent-updater`, and
the `serviceradar-agent` SHALL remain non-root. The sidecar's runtime behavior — eBPF/AF_XDP
capture, passive fingerprinting, DPI, flow attribution, and the events it forwards over the existing
agent IPC — is unchanged; this requirement supersedes delivering netprobe through the base agent
package.

#### Scenario: Operator enables netprobe from Edge Ops

- **GIVEN** a `serviceradar-agent` whose build includes the native add-on manager
- **AND** an approved netprobe `AddonPackage`
- **WHEN** an operator assigns the netprobe add-on to the agent (or its cohort) in Edge Ops
- **THEN** the signed netprobe artifact SHALL be delivered and activated via the root-owned `agent-updater`
- **AND** the required file capabilities SHALL be applied and the systemd service SHALL be installed and enabled
- **AND** the agent SHALL connect to the sidecar over its existing IPC and forward fingerprint, DPI, and flow-attribution events

#### Scenario: Unsigned or mis-signed artifact is rejected

- **GIVEN** a netprobe add-on artifact whose signature or `sha256` does not verify against the agent's trusted release key
- **WHEN** the agent attempts activation
- **THEN** activation SHALL be refused
- **AND** no netprobe binary SHALL be capability-granted and no netprobe service SHALL be installed or enabled
- **AND** any previously active netprobe version SHALL remain current

#### Scenario: Disabling the assignment stops capture

- **GIVEN** an agent running the netprobe add-on as a systemd service
- **WHEN** the netprobe assignment is disabled or unassigned in Edge Ops
- **THEN** the agent SHALL stop pushing visibility config and stop ingesting the netprobe IPC
- **AND** the privileged path SHALL disable the netprobe service
- **AND** the agent SHALL report the netprobe add-on as not active

#### Scenario: Base agent package installs no netprobe sidecar

- **GIVEN** an operator installs the standard `serviceradar-agent` RPM or deb
- **WHEN** the package post-install runs
- **THEN** it SHALL NOT install the `serviceradar-netprobe` binary, apply its file capabilities, or install or enable its service
- **AND** the netprobe sidecar SHALL be present only after the netprobe add-on is delivered

#### Scenario: Failed activation rolls back without a half-installed service

- **GIVEN** a newly delivered netprobe add-on version that fails signature verification, capability application, or launch
- **WHEN** the agent attempts to activate it
- **THEN** the previously active netprobe version SHALL remain current
- **AND** no partially installed or enabled netprobe service, and no running-but-incapable netprobe process, SHALL be left on the host

#### Scenario: Add-on state and drift are reported

- **GIVEN** a netprobe add-on assigned to an agent
- **WHEN** the agent reconciles the assignment
- **THEN** it SHALL report the netprobe add-on's installed/active/degraded state, version, and architecture through the add-on status read model
- **AND** Edge Ops SHALL surface assigned-but-not-active or arch-unsupported netprobe assignments as drift
