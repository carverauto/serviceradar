## ADDED Requirements

### Requirement: Guest Availability State-Change Event
The Proxmox plugin SHALL treat a monitored guest's `running` -> `stopped`
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

### Requirement: Guest Paused By The Hypervisor
The Proxmox plugin SHALL read the hypervisor runtime state of every QEMU guest
whose status is `running`, SHALL report a guest whose runtime state is not
`running` as not available, and SHALL emit a condition event when a guest
enters such a state and a recovery when it resumes.

#### Scenario: Guest is paused on an I/O error
- **GIVEN** a QEMU guest whose status is `running`
- **WHEN** a poll observes its runtime state is `io-error`
- **THEN** the plugin SHALL report the guest as not available
- **AND** SHALL emit a `com.carverauto.proxmox.guest_runtime_paused` condition
  event referencing the guest's canonical DeviceID, its Proxmox node and the
  runtime state

#### Scenario: Guest stays paused across polls
- **WHEN** a guest was already in the same non-running runtime state in the
  previous poll
- **THEN** the plugin SHALL NOT emit a repeat `guest_runtime_paused` event for
  that guest

#### Scenario: Paused guest resumes
- **GIVEN** a guest for which a `guest_runtime_paused` event was emitted
- **WHEN** a poll observes its runtime state is `running` again
- **THEN** the plugin SHALL report the guest as available
- **AND** SHALL emit the recovery for that guest's condition

#### Scenario: Runtime state cannot be read
- **WHEN** the runtime state of a running guest cannot be read
- **THEN** the plugin SHALL keep the availability derived from the guest's
  status
- **AND** SHALL NOT emit a `guest_runtime_paused` event for that guest

### Requirement: Node Storage Capacity Event
The Proxmox plugin SHALL emit a condition event, distinct from the periodic
resource-pressure summaries, when a node datastore enters the critical
capacity band, and SHALL emit a recovery when that datastore leaves it.

#### Scenario: Datastore crosses the critical threshold
- **WHEN** a poll observes a node datastore at or above the critical capacity
  threshold that was below it in the previous poll
- **THEN** the plugin SHALL emit a
  `com.carverauto.proxmox.node_storage_capacity` condition event carrying the
  node, the datastore name and the used and total bytes

#### Scenario: Datastore stays critical across polls
- **WHEN** a node datastore was already at or above the critical threshold in
  the previous poll
- **THEN** the plugin SHALL NOT emit a repeat `node_storage_capacity` event
  for that datastore

#### Scenario: Datastore recovers
- **GIVEN** a datastore for which a `node_storage_capacity` event was emitted
- **WHEN** a poll observes it below the critical threshold
- **THEN** the plugin SHALL emit the recovery for that datastore's condition

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
`guest-availability-changed`, `guest-runtime-paused`, `node-storage-capacity`
and `node-oom-kill` using the plugin-manifest alert-rule mechanism, so an
operator can enable them without hand-authoring rule definitions, and without
any rule being armed automatically. The `guest-runtime-paused` and
`node-storage-capacity` rules SHALL declare the recovery that closes their
alert.

#### Scenario: Plugin package is approved
- **WHEN** an operator approves a Proxmox plugin package whose manifest
  declares `alert_rules:` entries for `guest-availability-changed`,
  `guest-runtime-paused`, `node-storage-capacity` and `node-oom-kill`
- **THEN** each entry SHALL be materialized as a disabled
  `stateful_alert_rules` row namespaced `plugin:proxmox:<name>`
- **AND** no rule SHALL be enabled automatically

#### Scenario: Storage alert clears when the datastore recovers
- **GIVEN** the `plugin:proxmox:node-storage-capacity` rule is enabled and has
  an open alert for a datastore
- **WHEN** the plugin emits the recovery for that datastore
- **THEN** the alert SHALL resolve and no new alert SHALL open

#### Scenario: Operator enables a materialized rule
- **WHEN** an operator enables the `plugin:proxmox:guest-availability-changed`
  rule via the existing alert-rules UI
- **THEN** subsequent `guest_availability_changed` events matching that rule's
  window and threshold SHALL generate an `Alert` routed through the existing
  notification pipeline
