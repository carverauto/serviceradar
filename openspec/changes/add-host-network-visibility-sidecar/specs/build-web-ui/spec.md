## ADDED Requirements

### Requirement: Visibility Profile Management

The web-ng application SHALL expose a `Settings → Discovery →
Visibility Profiles` page that lets authorised operators create, edit,
enable, disable, and delete
`Serviceradar.Inventory.VisibilityProfile` records. The page MUST
follow the existing Sysmon and SNMP profile patterns: list view with
target counts, create/edit form with the shared SRQL `target_query`
builder, priority, per-capability toggles (`fingerprint` TCP/TLS/HTTP;
`dpi` protocols; `flow_attribution` TCP/UDP/QUIC),
`process_snapshot_interval_s`, `sample_interval_ms`, and
`retention_days`.

#### Scenario: Operator creates and enables a visibility profile
- **WHEN** an authorised operator submits a new profile with a valid
  `target_query`, `priority`, `enabled = true`, and at least one
  capability toggle on
- **THEN** the profile is persisted via the Ash resource
- **AND** the list view shows the new profile with its target count

#### Scenario: Invalid SRQL surfaces a target count of "Unknown"
- **WHEN** an operator enters a malformed SRQL string in the
  `target_query` builder
- **THEN** the list view shows "Unknown" rather than a numeric target
  count for that profile, matching the existing SNMP-profile
  target-count treatment

#### Scenario: Blank target query defaults to `in:devices`
- **WHEN** an operator leaves the `target_query` field empty and saves
  the profile
- **THEN** the profile is persisted with the default scope
- **AND** the list view shows a target count equal to the
  partition-scoped device total

### Requirement: Capture Interface Allowlist Editor

The Agent Detail page SHALL expose a Capture Interface Allowlist editor
for agents that advertise `host-network-visibility`. The editor MUST
present the agent's currently-reported interfaces, allow the operator
to opt each one in or out, refuse to accept `any` or wildcard entries,
and persist the result through the agent configuration pipeline.

#### Scenario: Wildcard entry is rejected by the editor
- **WHEN** an operator attempts to add `any` to the allowlist
- **THEN** the editor refuses to save and surfaces an inline error

#### Scenario: New interface appears and requires explicit opt-in
- **WHEN** the agent reports a new interface that is not on the
  allowlist
- **THEN** the editor shows it in an "Available, not capturing" list
- **AND** capture does not begin on it until the operator opts in and
  saves

### Requirement: Network Visibility Panel on Device Detail

The Device Detail page SHALL render a "Network Visibility" panel for
devices whose `metadata.passive_fingerprint` or `metadata.dpi` map is
populated. The panel MUST display, per signal present: the signature
or protocol identifier, confidence, observed-at timestamp, and the
originating agent's name. When the panel is rendered it MUST also
surface the classification provenance entry attributing any fields it
changed (per `device-inventory`'s `Classification Provenance
Visibility in Inventory`).

#### Scenario: Device with TCP-only signature renders one fingerprint section
- **WHEN** a device has `metadata.passive_fingerprint.tcp` populated
  but no TLS or HTTP entries
- **THEN** the panel renders exactly one TCP section under
  "Fingerprint"
- **AND** does not render empty placeholders for TLS or HTTP

#### Scenario: Device without visibility evidence hides the panel
- **WHEN** a device has neither `metadata.passive_fingerprint` nor
  `metadata.dpi`
- **THEN** the Device Detail page does not render the panel

### Requirement: Process Listeners Tab on Agent-Host Devices

The Device Detail page SHALL render a "Process Listeners" tab when the
device is also a `serviceradar-agent` host with
`metadata.local_processes` populated. The tab MUST list each entry's
5-tuple, `pid`, `comm`, redacted `cmdline`, `uid`, and (when present)
`container_id`. The view MUST respect the privacy posture: full
command lines MUST be shown only when the controlling profile has
opted into full-cmdline capture and the viewer holds the appropriate
RBAC permission.

#### Scenario: Redacted cmdline is shown by default
- **WHEN** a viewer without elevated permission opens the tab
- **THEN** each row's `cmdline` shows the redacted form
  (`<binary-path> <args-hash>`)
- **AND** the full argument string is not present anywhere in the
  rendered HTML

### Requirement: Attributed Flows View

The Flows dashboard SHALL expose an "Attributed Flows" view rendering
persisted `platform.ocsf_network_activity` rows whose OCSF payload was stamped
in place with `event_type = "attributed_flow"` by core correlation. The view
MUST include the standard NetFlow columns (timestamp, src/dst IP and port,
bytes, packets, protocol) plus attribution columns (`pid`, `comm`, redacted
`cmdline`, `uid`, `container_id`) from the agent-up process observation.

#### Scenario: Attributed flow row carries process columns
- **WHEN** core correlation stamps an existing OCSF flow row with attribution
  (`pid = 1234, comm = "nginx"`)
- **THEN** the row displays both the NetFlow tuple and the process
  attribution fields

#### Scenario: Unattributed flow row degrades gracefully
- **WHEN** a flow record arrived without attribution (no matching
  local socket on the source agent's host)
- **THEN** the row renders the NetFlow tuple normally
- **AND** the attribution columns render as `—`

### Requirement: Remote Packet Capture Session Authoring

The web-ng application SHALL expose a "Start Remote Capture" action on
the Agent Detail page (and on the Device Detail page when the device
is an agent host) for users holding `agent_capture:remote`. The
action MUST open a modal that collects `interface` (pre-filled with
allowlisted interfaces only), `bpf_filter`, `duration_s`, `snaplen`,
and `byte_cap`. The modal MUST enforce tenant cap ceilings inline and
MUST refuse to submit a request that exceeds them.

#### Scenario: Modal pre-fills allowlisted interfaces
- **WHEN** an authorised user opens the Start Remote Capture modal on
  an agent whose allowlist contains `eth0` and `eth1`
- **THEN** the interface picker shows exactly `eth0` and `eth1`
- **AND** does not allow the user to type a free-form interface name

#### Scenario: Modal blocks submission over tenant cap
- **WHEN** the tenant's `duration_s` ceiling is `60` and a user
  enters `duration_s = 600`
- **THEN** the modal blocks submission inline with a structured
  error
- **AND** the request never reaches `core-elx`

### Requirement: Active Remote Capture Session Surface

The web-ng application SHALL render an active-session card whenever a
`RemotePacketCaptureSession` is in the `active` state and visible to
the viewing user. The card MUST display the session id, elapsed
time, bytes streamed, and a "Stop" button gated on the requesting
user (or any holder of `agent_capture:remote` on the partition).
The Agent Detail page's `host-network-visibility` capability badge
MUST also reflect the active-session state so operators can spot
busy agents without opening the session list.

#### Scenario: Stopping an active session transitions state
- **WHEN** an authorised user clicks "Stop" on an active session
  card
- **THEN** the session record transitions to `aborted` within 5
  seconds
- **AND** the active-session card disappears from the page

#### Scenario: Capability badge reflects active session
- **WHEN** any agent in the partition has an active capture session
- **THEN** that agent's `host-network-visibility` badge on the
  Agents list page shows an "active capture" indicator

### Requirement: Capture History and Audit View

The web-ng application SHALL expose a "Capture history" view to
users holding `agent_capture:audit_view`, listing every historic
`RemotePacketCaptureSession` for the partition. The view MUST
display, per session, the requesting user, agent, interfaces,
`bpf_filter`, `duration_s`, `snaplen`, `byte_cap`, `bytes_streamed`,
final state, and timestamps for each state transition.

#### Scenario: Audit-only viewer cannot start a session
- **WHEN** a user holding only `agent_capture:audit_view` opens the
  Capture history view
- **THEN** the page renders the session list
- **AND** the "Start Remote Capture" action is not rendered on the
  Agent Detail page for that user

### Requirement: Agent Detail surfaces netprobe sidecar state

The Agent Detail page SHALL display the `netprobe` sidecar's runtime
state (per `agent-registry`'s `Sidecar runtime metadata surfaced on
agent records`), including the kernel BPF support indicator, and SHALL
render `host-network-visibility = degraded` distinctly from `enabled`
and `unavailable`.

#### Scenario: Degraded capability is visually distinct
- **WHEN** an agent's `host-network-visibility` capability is
  `degraded`
- **THEN** the Agent Detail page renders a yellow / warning indicator
- **AND** the page explains the degradation cause (e.g. "kernel does
  not support CAP_BPF split")
