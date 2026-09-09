## ADDED Requirements

### Requirement: Guest Availability State-Change Event
The Proxmox plugin SHALL treat a monitored guest's `running` → `stopped`
transition as a distinct, alertable condition event, independent of the
periodic ok/warning/critical resource-pressure summaries it already emits.

#### Scenario: Monitored guest stops between polls
- **WHEN** a poll observes a guest that was `running` in the previous poll is
  now `stopped`
- **THEN** the plugin SHALL emit a
  `com.carverauto.proxmox.guest_availability_changed` condition event
  referencing the guest's canonical DeviceID and its Proxmox node
- **AND** this event SHALL be distinct from, not merged into, the periodic
  resource-pressure summary events

#### Scenario: Guest remains stopped across polls
- **WHEN** a guest was already `stopped` in the previous poll and remains
  `stopped`
- **THEN** the plugin SHALL NOT emit a repeat
  `guest_availability_changed` event for that guest

### Requirement: Host OOM-Kill Detection
The Proxmox plugin SHALL detect Linux OOM-killer activity on each polled
Proxmox node and emit a condition event distinct from ratio-based
memory-pressure summaries.

#### Scenario: Kernel OOM-killer reaps a process
- **WHEN** a node poll observes new kernel log entries matching an OOM-kill
  pattern (e.g. "Out of memory: Killed process") since that node's last
  successful poll
- **THEN** the plugin SHALL emit a `com.carverauto.proxmox.node_oom_kill`
  condition event carrying the node name, the killed process name/pid when
  parseable from the log line, and the raw log line as event detail

#### Scenario: No new OOM-kill log entries
- **WHEN** no matching kernel log entries appear since the node's last
  successful poll
- **THEN** the plugin SHALL NOT emit a `node_oom_kill` event for that poll

### Requirement: Proxmox Alert Rule Catalog
The Proxmox plugin manifest SHALL declare alert rules for
`guest-availability-changed` and `node-oom-kill` using the plugin-manifest
alert-rule mechanism, so an operator can enable them without hand-authoring
rule definitions, and without either rule being armed automatically.

#### Scenario: Plugin package is approved
- **WHEN** an operator approves a Proxmox plugin package whose manifest
  declares `alert_rules:` entries for `guest-availability-changed` and
  `node-oom-kill`
- **THEN** each entry SHALL be materialized as a disabled
  `stateful_alert_rules` row namespaced `plugin:proxmox:<name>`
- **AND** neither rule SHALL be enabled automatically

#### Scenario: Operator enables a materialized rule
- **WHEN** an operator enables the `plugin:proxmox:guest-availability-changed`
  rule via the existing alert-rules UI
- **THEN** subsequent `guest_availability_changed` events matching that rule's
  window and threshold SHALL generate an `Alert` routed through the existing
  notification pipeline
