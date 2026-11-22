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
- **AND** the event SHALL carry a `condition_key` built from the target
  discriminator the plugin already uses as its condition-key prefix and the
  guest's canonical DeviceID, so two targets that stop the same VMID never
  share a key
- **AND** the event's `log_name` SHALL be `com.carverauto.proxmox.guest_availability_changed`, not the SDK default
  `events.ocsf.processed` the pressure summaries use, and its
  `unmapped.level` SHALL be `critical`
- **AND** this event SHALL be distinct from, not merged into, the periodic
  resource-pressure summary events

#### Scenario: Guest remains stopped across polls
- **WHEN** a guest was already `stopped` in the previous poll and remains
  `stopped`
- **THEN** the plugin SHALL NOT emit a repeat
  `guest_availability_changed` event for that guest

### Requirement: Guest Paused By The Hypervisor
The Proxmox plugin SHALL read the hypervisor runtime state of every QEMU guest
whose status is `running` and SHALL report such a guest whose runtime state is
not `running` as not available. Containers have no runtime state and keep the
availability derived from their status. The plugin keeps no state between
polls. Every node of every Proxmox target has its own guest-runtime condition
scope, whose id is built from the target discriminator the plugin already uses
as its condition-key prefix, the scope name `guest-runtime` and the node name. A guest's condition key is
built from that target discriminator, the node, the guest type and the VMID,
so two targets with the same node name and VMID never share a scope or a key.
A node's guest list counts as fully read only for the target that read it.
For every node whose guest list a target read fully in a poll, the plugin SHALL
emit a `com.carverauto.proxmox.guest_runtime_paused` condition event, in that
node's guest-runtime scope, for each QEMU guest of that list whose status is
`running` and whose runtime state is not `running`, and SHALL emit the
guest-runtime scope-complete marker of that node. The marker SHALL list the
condition keys of those guests and of every QEMU guest the list shows as
`running` whose runtime state could not be read, and SHALL omit every other
guest, including a guest the list shows as not running and a guest absent
from the list. The marker's key list is empty when no key qualifies.
Each condition event and each scope-complete marker SHALL use exactly the
fields listed under "Condition wire fields" in this change's design.md: the
event sets `unmapped.condition_key` to the condition key defined here,
`unmapped.condition_scope` to the scope id defined here and `unmapped.level`;
the marker is a separate record whose `unmapped.condition_scope_complete` is
that scope id and whose `unmapped.active_condition_keys` is a JSON array of
those same key strings, and it carries no condition key or level of its own.
Clearing follows the Scoped Condition Recovery requirement.

#### Scenario: Guest is paused on an I/O error
- **GIVEN** a QEMU guest whose status is `running`
- **WHEN** a poll reads its node's guest list fully and observes the guest's
  runtime state is `io-error`
- **THEN** the plugin SHALL report the guest as not available
- **AND** SHALL emit a `com.carverauto.proxmox.guest_runtime_paused` condition
  event whose `unmapped.condition_scope` is that node's guest-runtime scope
  id and whose `unmapped.condition_key` is the guest's key (target
  discriminator, node, guest type and VMID), carrying the guest's canonical
  DeviceID, its Proxmox node and the runtime state as event detail
- **AND** the event's `log_name` SHALL be `com.carverauto.proxmox.guest_runtime_paused`, not the SDK default
  `events.ocsf.processed` the pressure summaries use, and its
  `unmapped.level` SHALL be `warning` or `critical`
- **AND** SHALL include that same key string in the
  `unmapped.active_condition_keys` array of the node's guest-runtime
  scope-complete marker

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
  guest-runtime scope-complete marker
- **WHEN** a poll reads that node's guest list fully and observes the guest's
  runtime state is `running`
- **THEN** the plugin SHALL report the guest as available
- **AND** SHALL emit the node's guest-runtime scope-complete marker without
  that guest's condition key
- **AND** if the agent still remembers that key at a non-ok level in that
  node's guest-runtime scope, it SHALL forward exactly one clearing event for
  that key

#### Scenario: Paused guest stops or disappears
- **GIVEN** a guest whose condition key was listed in its node's previous
  guest-runtime scope-complete marker
- **WHEN** a poll reads that node's guest list fully and the list shows the
  guest as not running or does not contain it
- **THEN** the plugin SHALL emit the node's guest-runtime scope-complete
  marker without that guest's condition key
- **AND** if the agent still remembers that key at a non-ok level in that
  node's guest-runtime scope, it SHALL forward exactly one clearing event for
  that key

#### Scenario: Runtime state of one guest cannot be read
- **WHEN** a poll reads a node's guest list fully but cannot read the runtime
  state of a QEMU guest the list shows as `running`
- **THEN** the plugin SHALL keep that guest's availability derived from its
  status
- **AND** SHALL NOT emit a `guest_runtime_paused` event for that guest
- **AND** SHALL list that guest's condition key in the node's guest-runtime
  scope-complete marker, which keeps an alert the agent remembers for that
  guest open and opens none, while the other guests of the node clear as
  usual

#### Scenario: Guest list cannot be read
- **WHEN** the guest list of a polled node cannot be read fully
- **THEN** the plugin SHALL NOT emit that node's guest-runtime scope-complete
  marker, so no key of that scope is cleared by the incomplete read
- **AND** SHALL still emit the guest-runtime scope-complete marker of every
  other node whose guest list it read fully

#### Scenario: Two targets share a node name and VMID
- **GIVEN** two Proxmox targets that each have a node with the same name and
  a QEMU guest with the same VMID, one paused and one running
- **WHEN** a poll reads both guest lists fully
- **THEN** the two guests SHALL have different condition keys in different
  guest-runtime scopes
- **AND** the marker of the target whose guest is running SHALL NOT clear the
  other target's key

### Requirement: Node Storage Capacity Event
The Proxmox plugin SHALL emit a condition event, distinct from the periodic
resource-pressure summaries, for each node datastore in the critical capacity
band. The plugin keeps no state between polls. Storage is read per node, and
every node of every Proxmox target has its own node-storage condition scope,
whose id is built from the target discriminator the plugin already uses as its
condition-key prefix, the scope name `node-storage` and the node name. A datastore's condition key is built
from that target discriminator, the node and the datastore name only; used
and total bytes and ratios are event detail and never part of a key. A node's
storage counts as fully read only for the target that read it. For every node
whose storage a target read fully in a poll, the plugin SHALL emit a
`com.carverauto.proxmox.node_storage_capacity` condition event, in that node's
node-storage scope, for each datastore at or above the critical threshold and
SHALL emit the node-storage scope-complete marker of that node listing the
condition keys of those datastores, with an empty key list when none is
critical. The plugin's band classification decides membership, so the event
SHALL NOT carry the ratio and threshold fields the agent uses for hysteresis.
Each condition event and each scope-complete marker SHALL use exactly the
fields listed under "Condition wire fields" in this change's design.md: the
event sets `unmapped.condition_key` to the condition key defined here,
`unmapped.condition_scope` to the scope id defined here and `unmapped.level`;
the marker is a separate record whose `unmapped.condition_scope_complete` is
that scope id and whose `unmapped.active_condition_keys` is a JSON array of
those same key strings, and it carries no condition key or level of its own.
Clearing follows the Scoped Condition Recovery requirement.

#### Scenario: Datastore is at critical capacity
- **WHEN** a poll reads a node's storage fully and observes a datastore at or
  above the critical capacity threshold
- **THEN** the plugin SHALL emit a
  `com.carverauto.proxmox.node_storage_capacity` condition event whose
  `unmapped.condition_scope` is that node's node-storage scope id and whose
  `unmapped.condition_key` is the datastore's key (target discriminator, node
  and datastore name), carrying the node, the datastore name and the used and
  total bytes as event detail
- **AND** the event's `log_name` SHALL be `com.carverauto.proxmox.node_storage_capacity`, not the SDK default
  `events.ocsf.processed` the pressure summaries use, and its
  `unmapped.level` SHALL be `critical`
- **AND** SHALL include that same key string in the
  `unmapped.active_condition_keys` array of the node's node-storage
  scope-complete marker

#### Scenario: Datastore stays critical across polls
- **WHEN** consecutive polls read the node's storage fully and observe the
  same datastore at or above the critical threshold with different used bytes
- **THEN** the plugin SHALL emit the condition event and list the same key on
  each of those polls
- **AND** the agent SHALL forward the condition event on its first
  observation, on a level change and on its unchanged-level refresh, and
  SHALL NOT clear it while its key stays listed

#### Scenario: Datastore recovers
- **GIVEN** a datastore whose condition key was listed in its node's previous
  node-storage scope-complete marker
- **WHEN** a poll reads that node's storage fully and observes the datastore
  below the critical threshold or no longer reports it
- **THEN** the plugin SHALL emit the node's node-storage scope-complete marker
  without that datastore's condition key
- **AND** if the agent still remembers that key at a non-ok level in that
  node's node-storage scope, it SHALL forward exactly one clearing event for
  that key

#### Scenario: Node storage cannot be read
- **WHEN** the storage of a polled node cannot be read fully
- **THEN** the plugin SHALL NOT emit that node's node-storage scope-complete
  marker, so no key of that scope is cleared by the incomplete read
- **AND** SHALL still emit the node-storage scope-complete marker of every
  other node whose storage it read fully

#### Scenario: Guest and storage markers of one node
- **WHEN** a poll reads a node's guest list and storage fully
- **THEN** the guest-runtime marker SHALL NOT clear a node-storage key and the
  node-storage marker SHALL NOT clear a guest-runtime key

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
- **AND** the event SHALL carry a `condition_key` built from the target
  discriminator, the node and the log entry's own identity (its timestamp and
  raw line), so two kills are distinct alert groups
- **AND** the event's `log_name` SHALL be `com.carverauto.proxmox.node_oom_kill`, not the SDK default
  `events.ocsf.processed` the pressure summaries use, and its
  `unmapped.level` SHALL be `critical`

#### Scenario: No new OOM-kill log entries
- **WHEN** no matching kernel log entries appear since the node's last
  successful poll
- **THEN** the plugin SHALL NOT emit a `node_oom_kill` event for that poll

### Requirement: Proxmox Alert Rule Catalog
The Proxmox plugin manifest SHALL declare alert rules for
`guest-availability-changed`, `guest-runtime-paused`, `node-storage-capacity`
and `node-oom-kill` using the plugin-manifest alert-rule mechanism, so an
operator can enable them without hand-authoring rule definitions, and without
any rule being armed automatically. Each of the four entries SHALL declare
signal `event`, threshold 1 and group_by `condition_key`, and SHALL NOT set
`enabled` or `priority`. Each rule's opening match SHALL be `subject_prefix`
on its own event's `log_name` (`com.carverauto.proxmox.guest_availability_changed`,
`com.carverauto.proxmox.guest_runtime_paused`,
`com.carverauto.proxmox.node_storage_capacity` and
`com.carverauto.proxmox.node_oom_kill` respectively) plus `attribute_equals`
on `level` listing `warning` and `critical`. The `guest-runtime-paused` and
`node-storage-capacity` rules SHALL declare as their recovery the same
`subject_prefix` with `attribute_equals` on `level` equal to `ok`, which is the clearing event the agent
synthesizes under the Scoped Condition Recovery requirement and which carries
the same `condition_key`. Because the opening match requires a non-ok level
on the rule's own subject, the clearing event never opens or extends an
alert, and the existing `node_storage` pressure summaries are never matched.
The `guest-runtime-paused` and `node-storage-capacity` rules SHALL declare
`cooldown_seconds` 1800: their condition is re-emitted while it holds and the
agent forwards an unchanged level only on its 15-minute refresh, so a
cooldown comfortably above that interval keeps a condition that stays active
one incident instead of resolving and re-opening on each refresh. The
`guest-availability-changed` and `node-oom-kill` rules keep the default
cooldown.

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
- **AND** a `node_storage` pressure summary for the same datastore SHALL NOT
  open or hold an alert on this rule

#### Scenario: A condition that stays active remains one alert
- **GIVEN** the `plugin:proxmox:guest-runtime-paused` or
  `plugin:proxmox:node-storage-capacity` rule is enabled and has an open
  alert for a guest or datastore
- **WHEN** the guest stays paused, or the datastore stays critical, across
  several of the agent's unchanged-level refreshes
- **THEN** the alert SHALL remain a single open alert and SHALL NOT resolve
  and re-open on any refresh

#### Scenario: One event opens an alert per condition key
- **GIVEN** the `plugin:proxmox:guest-runtime-paused` rule is enabled
- **WHEN** a single `guest_runtime_paused` event is forwarded for a guest
- **THEN** an alert SHALL open for that guest's condition key
- **AND** a clearing event for a different guest's or datastore's condition
  key SHALL NOT resolve it

#### Scenario: Operator enables a materialized rule
- **WHEN** an operator enables the `plugin:proxmox:guest-availability-changed`
  rule via the existing alert-rules UI
- **THEN** subsequent `guest_availability_changed` events matching that rule's
  window and threshold SHALL generate an `Alert` routed through the existing
  notification pipeline
