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
whose status is `running` and SHALL report a guest whose runtime state is not
`running` as not available. The plugin keeps no state between polls. Each
node's guest list has its own guest-runtime condition scope, and a guest's
condition key is derived from its node, guest type and VMID alone. For every node
whose guest list it read fully in a poll, the plugin SHALL emit a
`com.carverauto.proxmox.guest_runtime_paused` condition event for each guest
of that list in a non-running runtime state and SHALL emit that node's
scope-complete marker. The marker SHALL list the condition keys of those
guests and of every guest the list shows as `running` whose runtime state
could not be read, and SHALL omit every other guest, including a guest the
list shows as not running and a guest absent from the list. The marker's key
list is empty when no key qualifies. Clearing follows the Scoped Condition
Recovery requirement.

#### Scenario: Guest is paused on an I/O error
- **GIVEN** a QEMU guest whose status is `running`
- **WHEN** a poll reads its node's guest list fully and observes the guest's
  runtime state is `io-error`
- **THEN** the plugin SHALL report the guest as not available
- **AND** SHALL emit a `com.carverauto.proxmox.guest_runtime_paused` condition
  event at a non-ok level, in that node's condition scope, referencing the
  guest's canonical DeviceID, its Proxmox node and the runtime state
- **AND** SHALL list that guest's condition key in the node's scope-complete
  marker

#### Scenario: Guest stays paused across polls
- **WHEN** consecutive polls read the node's guest list fully and observe the
  guest in the same non-running runtime state
- **THEN** the plugin SHALL emit the condition event and list its key on each
  of those polls
- **AND** the agent SHALL forward the condition event on its first
  observation, on a level change and on its unchanged-level refresh, and
  SHALL NOT clear it while its key stays listed

#### Scenario: Paused guest resumes
- **GIVEN** a guest whose condition key was listed in its node's previous
  scope-complete marker
- **WHEN** a poll reads that node's guest list fully and observes the guest's
  runtime state is `running`
- **THEN** the plugin SHALL report the guest as available
- **AND** SHALL emit the node's scope-complete marker without that guest's
  condition key
- **AND** if the agent still remembers that key at a non-ok level in that
  node's guest-runtime scope, it SHALL forward exactly one clearing event for
  that key

#### Scenario: Paused guest stops or disappears
- **GIVEN** a guest whose condition key was listed in its node's previous
  scope-complete marker
- **WHEN** a poll reads that node's guest list fully and the list shows the
  guest as not running or does not contain it
- **THEN** the plugin SHALL emit the node's scope-complete marker without
  that guest's condition key
- **AND** if the agent still remembers that key at a non-ok level in that
  node's guest-runtime scope, it SHALL forward exactly one clearing event for
  that key

#### Scenario: Runtime state of one guest cannot be read
- **WHEN** a poll reads a node's guest list fully but cannot read the runtime
  state of a guest the list shows as `running`
- **THEN** the plugin SHALL keep that guest's availability derived from its
  status
- **AND** SHALL NOT emit a `guest_runtime_paused` event for that guest
- **AND** SHALL list that guest's condition key in the node's scope-complete
  marker, which keeps an alert the agent remembers for that guest open and
  opens none, while the other guests of the node clear as usual

#### Scenario: Guest list cannot be read
- **WHEN** the guest list of a polled node cannot be read fully
- **THEN** the plugin SHALL NOT emit that node's scope-complete marker, so no
  key of that node is cleared by the incomplete read
- **AND** SHALL still emit the scope-complete marker of every other node whose
  guest list it read fully

### Requirement: Node Storage Capacity Event
The Proxmox plugin SHALL emit a condition event, distinct from the periodic
resource-pressure summaries, for each node datastore in the critical capacity
band. The plugin keeps no state between polls. Storage is read per node, and
each node has its own node-storage condition scope. For every node whose
storage it read fully in a poll, the plugin SHALL emit a
`com.carverauto.proxmox.node_storage_capacity` condition event for each
datastore at or above the critical threshold and SHALL emit that node's
scope-complete marker listing the condition keys of those datastores, with an
empty key list when none is critical. The plugin's band classification decides
membership, so the event SHALL NOT carry the ratio and threshold fields the
agent uses for hysteresis. Clearing follows the Scoped Condition Recovery
requirement.

#### Scenario: Datastore is at critical capacity
- **WHEN** a poll reads a node's storage fully and observes a datastore at or
  above the critical capacity threshold
- **THEN** the plugin SHALL emit a
  `com.carverauto.proxmox.node_storage_capacity` condition event at the
  critical level, in that node's condition scope, carrying the node, the
  datastore name and the used and total bytes
- **AND** SHALL list that datastore's condition key in the node's
  scope-complete marker

#### Scenario: Datastore stays critical across polls
- **WHEN** consecutive polls read the node's storage fully and observe the
  same datastore at or above the critical threshold
- **THEN** the plugin SHALL emit the condition event and list its key on each
  of those polls
- **AND** the agent SHALL forward the condition event on its first
  observation, on a level change and on its unchanged-level refresh, and
  SHALL NOT clear it while its key stays listed

#### Scenario: Datastore recovers
- **GIVEN** a datastore whose condition key was listed in its node's previous
  scope-complete marker
- **WHEN** a poll reads that node's storage fully and observes the datastore
  below the critical threshold or no longer reports it
- **THEN** the plugin SHALL emit the node's scope-complete marker without
  that datastore's condition key
- **AND** if the agent still remembers that key at a non-ok level in that
  node's node-storage scope, it SHALL forward exactly one clearing event for
  that key

#### Scenario: Node storage cannot be read
- **WHEN** the storage of a polled node cannot be read fully
- **THEN** the plugin SHALL NOT emit that node's scope-complete marker, so no
  key of that node is cleared by the incomplete read
- **AND** SHALL still emit the scope-complete marker of every other node whose
  storage it read fully

### Requirement: Scoped Condition Recovery
The guest-runtime and node-storage conditions SHALL rely on the agent's
existing condition debounce for de-duplication and recovery, with no state in
the plugin. The agent forwards a condition event on its first observation, on
a level change and on its unchanged-level refresh. When a scope-complete
marker omits a key the agent still remembers at a non-ok level in that same
scope, the agent forwards one clearing event for that key. A marker never
opens a key. No marker, another scope's marker, an agent restart, or the
expiry of the remembered key clears nothing; an alert left open that way
stays open until an operator resolves it.

#### Scenario: Marker of the same scope omits a remembered key
- **GIVEN** the agent remembers a key at a non-ok level in a scope
- **WHEN** a scope-complete marker for that scope omits the key
- **THEN** the agent SHALL forward exactly one clearing event for that key

#### Scenario: Marker cannot open or clear outside its scope
- **WHEN** a scope-complete marker lists a key the agent does not remember,
  or a marker for another scope omits a remembered key
- **THEN** the agent SHALL forward nothing for that key

#### Scenario: Remembered key is lost
- **GIVEN** the agent restarted or the remembered key expired
- **WHEN** a later scope-complete marker omits the key
- **THEN** the agent SHALL forward no clearing event for that key

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
`node-storage-capacity` rules SHALL declare as their recovery the clearing
event the agent synthesizes under the Scoped Condition Recovery requirement.

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
- **WHEN** the node's next node-storage scope-complete marker no longer lists
  that datastore's condition key and the agent forwards the clearing event
- **THEN** the alert SHALL resolve and no new alert SHALL open

#### Scenario: Operator enables a materialized rule
- **WHEN** an operator enables the `plugin:proxmox:guest-availability-changed`
  rule via the existing alert-rules UI
- **THEN** subsequent `guest_availability_changed` events matching that rule's
  window and threshold SHALL generate an `Alert` routed through the existing
  notification pipeline
