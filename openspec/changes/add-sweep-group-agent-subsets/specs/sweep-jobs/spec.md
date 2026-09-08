# sweep-jobs

## MODIFIED Requirements

### Requirement: Sweep Job Configuration

The system SHALL provide Ash resources for defining sweep jobs that target
specific devices or device selections and run on all eligible partition agents
or an explicit set of known agents.

#### Scenario: Create sweep job by device query
- **GIVEN** an admin in Settings > Networks
- **WHEN** they create a sweep job with an SRQL device query
- **THEN** they SHALL be able to filter by:
  - Tags (keys or key/value pairs)
  - IPs/CIDRs/ranges
  - Partition
- **AND** the SRQL query SHALL be saved and re-evaluated on each sweep

#### Scenario: Assign sweep job to partition
- **GIVEN** a sweep job configuration
- **WHEN** the user selects a partition and chooses all eligible agents
- **THEN** the job SHALL be assigned to that device partition
- **AND** every sweep-eligible agent in that partition SHALL receive the job

#### Scenario: Assign sweep job to one agent
- **GIVEN** a sweep job configuration
- **WHEN** the user selects one known agent
- **THEN** only that agent SHALL execute the job
- **AND** the agent SHALL receive the config via its next config delivery
- **AND** the behavior SHALL match the former scalar `agent_id` assignment

#### Scenario: Assign sweep job to an agent subset
- **GIVEN** a sweep job configuration
- **WHEN** the user selects multiple known agents
- **THEN** the stored assignment SHALL contain unique, non-blank agent UIDs
- **AND** every selected agent SHALL receive the job independently through
  scheduled config delivery
- **AND** an unselected agent SHALL NOT receive the job

#### Scenario: Preserve cross-partition isolation assignment
- **GIVEN** a sweep group whose partition identifies the target-device
  partition
- **AND** a selected scanner agent whose control-session partition is different
- **WHEN** configuration is compiled for that selected agent
- **THEN** the agent SHALL receive the group despite the partition difference
- **AND** the group SHALL continue to resolve devices from its configured
  target-device partition

#### Scenario: Keep a known offline agent assigned
- **GIVEN** a known selected agent is offline, disconnected, degraded, or
  unavailable
- **WHEN** the sweep group is saved
- **THEN** the assignment SHALL remain valid
- **AND** scheduled configuration SHALL be delivered when the agent reconnects

#### Scenario: Reject a newly added unknown agent
- **GIVEN** Selected agents mode newly adds an agent UID that cannot be
  resolved through the current scope
- **WHEN** the user saves the sweep group
- **THEN** the save SHALL fail with a field-level assignment error
- **AND** the invalid UID SHALL NOT be silently removed or broadened to all
  agents

#### Scenario: Preserve an unresolved existing assignment
- **GIVEN** an existing or migrated sweep group already contains an agent UID
  that no longer resolves
- **WHEN** the user saves an unrelated description or schedule edit without
  adding that UID in the request
- **THEN** the unresolved assignment SHALL remain stored and visibly marked
  unavailable
- **AND** the unrelated edit SHALL NOT be blocked or broadened to all agents

#### Scenario: Replace a superseded agent without collapsing the subset
- **GIVEN** an explicit subset contains an agent UID that is superseded during
  agent gateway re-enrollment
- **WHEN** gateway synchronization transfers assignments to the replacement UID
- **THEN** the superseded UID SHALL be replaced in any array position
- **AND** every other selected UID SHALL remain assigned
- **AND** if the replacement UID is already selected, the canonical array SHALL
  contain it only once

#### Scenario: Capability snapshot is advisory for persistence
- **GIVEN** a known selected agent is offline or its persisted capabilities no
  longer advertise `sweep`
- **WHEN** the user saves the existing assignment
- **THEN** the assignment SHALL remain valid
- **AND** the UI SHALL display the current capability/status context
- **AND** `Run now` SHALL use live-session capability to decide whether that
  agent can be dispatched

### Requirement: Sweep Job Compiled Config Output

The system SHALL compile sweep job configurations into the agent-consumable
JSON format matching the existing `sweep.json` schema and SHALL determine group
eligibility server-side from the requesting agent UID and partition.

#### Scenario: Compile sweep config for agent
- **GIVEN** a sweep job assigned to an agent
- **WHEN** the agent polls for config
- **THEN** the compiled config SHALL include:
  - `networks`: CIDR ranges from device query evaluation
  - `ports`: from selected profile or job override
  - `sweep_modes`: ["tcp", "icmp", "tcp_connect"] based on profile
  - `interval`: scan interval duration
  - `concurrency`: parallel scan threads
  - `timeout`: per-target timeout
  - `icmp_count`, `high_perf_icmp`, `icmp_rate_limit`: ICMP settings
  - `device_targets`: per-device configurations with metadata

#### Scenario: Device query evaluation at compile time
- **GIVEN** a sweep job with device query "tags.env = 'prod'"
- **WHEN** the config is compiled
- **THEN** the query SHALL be evaluated against current device inventory
- **AND** matching device IPs SHALL populate `networks` as /32 CIDRs
- **AND** device metadata SHALL populate `device_targets` entries

#### Scenario: Merge multiple sweep jobs
- **GIVEN** multiple sweep jobs assigned to the same agent
- **WHEN** the agent polls for config
- **THEN** the configs SHALL be merged into a single sweep config
- **AND** networks and device_targets SHALL be combined
- **AND** the most restrictive settings SHALL be used for shared targets

#### Scenario: Agent parses device targets with TCP ports
- **GIVEN** a sweep config with device targets from `in:devices` query
- **AND** TCP ports configured in the sweep profile
- **WHEN** the agent receives and parses the sweep config
- **THEN** the agent SHALL parse the `device_targets` field from the gateway
  payload
- **AND** TCP port scans SHALL be generated for each device target using the
  profile ports
- **AND** both ICMP and TCP targets SHALL be created when both modes are enabled

#### Scenario: Profile ports are preserved for device-targeted sweeps
- **GIVEN** a sweep group with `target_query` using `in:devices`
- **AND** a sweep profile with non-empty TCP ports
- **AND** the sweep group does not override ports
- **WHEN** the sweep config is compiled
- **THEN** the compiled `ports` list SHALL include the profile ports
- **AND** TCP targets SHALL be generated for those ports

#### Scenario: TCP mode requires ports
- **GIVEN** a sweep group with TCP mode enabled
- **AND** no TCP ports are configured on the group or its profile
- **WHEN** the sweep config is compiled
- **THEN** the system SHALL surface a warning/error in logs
- **AND** the config SHALL NOT silently run TCP scans with an empty ports list

#### Scenario: Compile an explicit agent subset
- **GIVEN** a sweep group assigned to agents A and B
- **WHEN** sweep configuration is compiled for agents A, B, and C
- **THEN** the existing group JSON SHALL be included independently for agents A
  and B
- **AND** it SHALL be absent from agent C's config
- **AND** the agent-facing group JSON SHALL NOT require a new assignment field

#### Scenario: Compile selected groups only for a concrete agent identity
- **GIVEN** a sweep group has a non-empty selected-agent assignment
- **WHEN** configuration is requested without a non-blank agent UID
- **THEN** the selected group SHALL NOT be included
- **AND** an absent identity SHALL NOT bypass selected-agent membership

#### Scenario: Remove a group from a deselected agent
- **GIVEN** a sweep group was assigned to agents A and B
- **WHEN** the assignment is changed to only agent A
- **THEN** sweep config SHALL be invalidated for both agents
- **AND** the next config for agent B SHALL omit the group

### Requirement: Sweep Job Admin UI

The system SHALL provide an admin interface for managing sweep jobs in Settings
> Networks, including scalable selection of all eligible agents or an explicit
agent subset.

#### Scenario: View configured sweep jobs
- **GIVEN** an admin in Settings > Networks
- **WHEN** they view the sweep jobs list
- **THEN** they SHALL see all sweep jobs for the tenant
- **AND** each job SHALL display name, profile, target count, partition, agent
  assignment summary, and status

#### Scenario: View sweep job status
- **GIVEN** a configured sweep job
- **WHEN** viewing the job details
- **THEN** the status SHALL show:
  - Last execution time
  - Next scheduled execution
  - Execution duration
  - Target count and completion percentage
  - Error count and last error

#### Scenario: Edit sweep job
- **GIVEN** an existing sweep job
- **WHEN** an admin edits the job
- **THEN** changes SHALL be saved to the database
- **AND** a config invalidation event SHALL be published
- **AND** the assigned agent(s) SHALL receive updated config on next poll

#### Scenario: Delete sweep job
- **GIVEN** an existing sweep job
- **WHEN** an admin deletes the job
- **THEN** the job SHALL be removed from the database
- **AND** its executions and their per-host results SHALL be discarded with it
- **AND** long-term coverage rollups SHALL be retained
- **AND** the agent config SHALL be recompiled without this job

#### Scenario: Choose assignment mode explicitly
- **GIVEN** an operator creates or edits a sweep group
- **WHEN** they view the agent assignment control
- **THEN** they SHALL be able to choose All eligible agents or Selected agents
- **AND** All eligible agents SHALL be summarized as `All agents`
- **AND** Selected agents SHALL require at least one selected UID

#### Scenario: Browse a large agent fleet
- **GIVEN** an installation has thousands of known agents
- **WHEN** the operator opens the selected-agent picker
- **THEN** the modal SHALL load at most 50 agents rather than the entire fleet
- **AND** the operator SHALL be able to search by display name or UID
- **AND** the operator SHALL be able to navigate keyset-paginated results
- **AND** results SHALL have a stable case-folded-name then UID order

#### Scenario: Open a sweep-group form without eager fleet loading
- **GIVEN** an installation has thousands of known agents
- **WHEN** the operator opens a new or existing sweep-group form without
  opening the picker
- **THEN** the route SHALL NOT execute an unpaginated all-agent read
- **AND** the LiveView SHALL NOT assign or render a fleet-wide Agent collection

#### Scenario: Reset pagination when search changes
- **GIVEN** the operator has navigated away from the first picker page
- **WHEN** the normalized search text changes
- **THEN** the picker SHALL discard cursor history and load the first page for
  the new query
- **AND** a cursor issued for the prior query SHALL NOT be reused

#### Scenario: Preserve selections across search and pages
- **GIVEN** the operator selects agents on one result page
- **WHEN** they search or navigate to another page and select more agents
- **THEN** the earlier selections SHALL remain in the draft selection
- **AND** returning to a prior result SHALL show its selected state

#### Scenario: Apply or cancel picker changes
- **GIVEN** the operator changes the draft selection in the modal
- **WHEN** they choose Apply
- **THEN** a non-empty normalized selection SHALL become the canonical
  Selected-mode form value
- **WHEN** they instead choose Cancel, press Escape, or dismiss the backdrop
- **THEN** the form's prior selection SHALL remain unchanged

#### Scenario: Selected mode cannot submit an empty list
- **GIVEN** the sweep-group form is in Selected agents mode
- **WHEN** a client submits no selected UIDs through hidden or crafted params
- **THEN** validation SHALL fail instead of interpreting the empty list as All
  agents
- **AND** switching deliberately to All agents SHALL clear every stale
  selected UID

#### Scenario: Display a concise subset summary
- **GIVEN** a sweep group has one or multiple selected agents
- **WHEN** the form, list, or detail view renders the assignment
- **THEN** one selection SHALL show the agent display name
- **AND** multiple selections SHALL show the selected count
- **AND** an assigned UID that no longer resolves SHALL be shown as unavailable
  until the operator removes it

#### Scenario: Bound summaries for a large selected subset
- **GIVEN** a sweep group contains thousands of selected UIDs
- **WHEN** the closed form control or list summary renders
- **THEN** the UI SHALL render the selected count without loading every Agent
  record
- **AND** opening or searching the picker SHALL still load only one bounded
  result page

#### Scenario: Inspect and remove one unavailable selection
- **GIVEN** a draft contains thousands of selected UIDs including one UID that
  no longer resolves
- **WHEN** the operator opens the picker's Selected view and navigates to that
  UID
- **THEN** the view SHALL render at most 50 selected rows in stable UID order
- **AND** the unresolved row SHALL display its raw UID as unavailable
- **WHEN** the operator removes that row
- **THEN** every other draft selection SHALL remain unchanged

#### Scenario: Recover from picker query failure
- **GIVEN** the operator has a non-empty draft selection
- **WHEN** a server-side search or pagination query fails
- **THEN** the modal SHALL show a recoverable error state
- **AND** the draft selection and count SHALL remain unchanged
- **AND** retrying or changing search SHALL be possible without closing the
  form

#### Scenario: Operate the picker with keyboard and assistive technology
- **GIVEN** the selected-agent picker is open
- **WHEN** the operator searches, selects, paginates, applies, or cancels with a
  keyboard or assistive technology
- **THEN** checkbox labels SHALL identify agent name, UID, and status
- **AND** selection-count changes SHALL be announced
- **AND** pagination controls SHALL have directional labels
- **AND** every close path SHALL restore focus to the picker trigger

### Requirement: Sweep Job Execution Tracking

The system SHALL track sweep job execution status and history with accurate
host totals and availability counts derived from sweep results, including one
execution record per reporting agent for shared assignments.

#### Scenario: Agent reports sweep completion
- **GIVEN** an agent completing a sweep job
- **WHEN** the sweep finishes
- **THEN** core SHALL record total hosts scanned, hosts available, and hosts
  failed for the execution
- **AND** the completion time and duration SHALL be recorded
- **AND** the values SHALL reflect cumulative results for the execution (not
  per-batch deltas)

#### Scenario: Active scan progress updates
- **GIVEN** an in-progress sweep execution
- **WHEN** progress batches are ingested
- **THEN** core SHALL update the execution with cumulative progress metrics
- **AND** the Active Scans UI SHALL display the current totals and completion
  percentage

#### Scenario: Selected agents report independently
- **GIVEN** a sweep group assigned to agents A and B
- **WHEN** both agents execute the group
- **THEN** each agent SHALL have an execution record carrying its own agent UID
- **AND** the expected reports SHALL NOT be logged as an assigned-group
  multi-agent conflict

#### Scenario: Unexpected agent reports a selected group
- **GIVEN** a sweep group has a non-empty selected-agent assignment
- **WHEN** an agent outside that assignment submits results for the group
- **THEN** core SHALL record an anomalous-assignment diagnostic containing the
  group and reporter UIDs
- **AND** the reporter's per-agent execution and availability observation SHALL
  remain available for diagnostics and forensics
- **AND** the reporter SHALL NOT gain implicit authority over canonical device
  availability merely by naming the group

#### Scenario: Configured availability source remains authoritative
- **GIVEN** a device has an `availability_source_agent_id`
- **WHEN** selected and unselected agents report availability observations for
  that device
- **THEN** the latest fresh observation from the configured source SHALL drive
  canonical device availability
- **AND** every reporter's per-agent availability observation SHALL remain
  independently queryable

#### Scenario: Unconfigured availability uses the canonical fallback
- **GIVEN** a device has no configured availability source
- **WHEN** expected and unexpected sweep-group reporters submit availability
  observations for that device
- **THEN** canonical device availability SHALL use the deterministic
  consolidated fallback defined by the per-agent availability capability over
  expected reporters only
- **AND** an unexpected reporter's observation SHALL remain queryable for
  forensics but SHALL NOT participate in the unconfigured fallback
- **AND** sweep-group assignment cardinality SHALL NOT define a separate
  availability-authority policy

#### Scenario: Group last run reflects any member report
- **GIVEN** a sweep group is assigned to agents A and B
- **WHEN** agent A reports a completed execution and agent B does not
- **THEN** the group's `last_run_at` SHALL equal the latest reported execution
  time from agent A
- **AND** the group-level status SHALL NOT imply that agent B reported
- **AND** the per-agent execution records SHALL remain available for inspecting
  member coverage

### Requirement: On-demand sweeps via command bus

The system SHALL allow admins to trigger sweep group execution on demand via
the command bus for every online agent in the group's effective assignment.

#### Scenario: Run partition-wide sweep group now
- **GIVEN** a sweep group assigned to all eligible agents in a partition
- **WHEN** the admin selects `Run now`
- **THEN** the system SHALL send a sweep command to every online sweep-capable
  agent in that partition
- **AND** the UI SHALL receive command status updates

#### Scenario: Run selected-agent sweep group now
- **GIVEN** a sweep group assigned to a fixed agent subset
- **WHEN** the admin selects `Run now`
- **THEN** the system SHALL send one sweep command to every selected online
  sweep-capable agent
- **AND** each command SHALL use that agent's live control-session partition

#### Scenario: Selected online agent lacks live sweep capability
- **GIVEN** a selected agent has an online control session without the `sweep`
  capability
- **WHEN** the admin selects `Run now`
- **THEN** that agent SHALL receive a per-agent dispatch failure
- **AND** the persisted group assignment SHALL remain unchanged

#### Scenario: Selected agent has an ambiguous control session
- **GIVEN** a selected agent resolves to no unique canonical live
  control-session partition
- **WHEN** the admin selects `Run now`
- **THEN** that agent SHALL receive a per-agent dispatch failure
- **AND** the system SHALL NOT fall back to the sweep group's device partition

#### Scenario: Run sweep group with partial selected availability
- **GIVEN** some selected agents are online and others are offline or fail
  dispatch
- **WHEN** the admin selects `Run now`
- **THEN** the online agents SHALL still receive the command
- **AND** the result SHALL identify successful command IDs and per-agent
  failures
- **AND** the UI SHALL present the dispatch as partial rather than complete

#### Scenario: Run sweep group while all effective agents are offline
- **GIVEN** no agent in the sweep group's effective assignment is online
- **WHEN** the admin selects `Run now`
- **THEN** the system SHALL return an immediate error

#### Scenario: Track selected-agent command status independently
- **GIVEN** run-now dispatch created commands for selected agents A and B
- **WHEN** either command publishes a later status update
- **THEN** the status SHALL be keyed by command ID and agent UID within the
  sweep group
- **AND** an update for agent A SHALL NOT overwrite agent B's status
- **AND** the group summary SHALL show aggregate success, pending, and failure
  counts

## ADDED Requirements

### Requirement: Sweep Assignment Migration Compatibility

The system SHALL migrate scalar sweep-group assignment to array assignment
without breaking mixed-version rolling deployments or broadening a subset when
an old reader is briefly present or restored.

#### Scenario: Expand schema while an old writer remains active
- **GIVEN** the `agent_ids` array has been added and an old application pod
  still writes scalar `agent_id`
- **WHEN** the old pod creates or updates an all-agent or single-agent sweep
  group
- **THEN** a temporary database compatibility trigger SHALL mirror the scalar
  value into the semantically equivalent `agent_ids` value
- **AND** array-aware readers SHALL observe the write without waiting for the
  old pod to be replaced

#### Scenario: Preserve a subset across an unrelated old-writer update
- **GIVEN** a multi-member canonical array has a fail-narrow first-member
  scalar projection
- **WHEN** an old writer resubmits that unchanged scalar while updating an
  unrelated sweep-group field
- **THEN** the compatibility trigger SHALL preserve the complete `agent_ids`
  array
- **AND** only an actual scalar assignment change SHALL replace the canonical
  array with an old writer's All or one-agent selection

#### Scenario: Project a new subset safely for an old reader
- **GIVEN** an array-aware pod saves a normalized selection with more than one
  agent UID while an old scalar reader may still be serving
- **WHEN** both canonical and compatibility fields are written
- **THEN** `agent_ids` SHALL retain the complete normalized selection
- **AND** scalar `agent_id` SHALL store the first normalized selected UID
- **AND** the old reader SHALL therefore reach at most one actually selected
  agent and SHALL NOT broaden the group to all partition agents

#### Scenario: Maintain the scalar bridge during the rollback window
- **GIVEN** scalar `agent_id` remains for mixed-version or rollback readers
- **WHEN** array-aware code saves an empty, single-member, or multi-member
  assignment
- **THEN** scalar `agent_id` SHALL respectively store nil, the selected UID, or
  the first normalized selected UID in the same write
- **AND** behavioral reads SHALL continue to use only `agent_ids`

#### Scenario: Preserve the canonical subset across rollback
- **GIVEN** a multi-member array exists and the application temporarily rolls
  back to a scalar-only binary
- **WHEN** the old binary reads the group
- **THEN** it SHALL see the fail-narrow first-member scalar projection
- **AND** the complete canonical `agent_ids` array SHALL remain stored for the
  next array-aware deployment

#### Scenario: Remove the scalar bridge after deprecation
- **GIVEN** no deployed reader or writer uses scalar `agent_id`
- **AND** no supported rollback binary requires it
- **WHEN** the later cleanup migration runs
- **THEN** the compatibility trigger, obsolete scalar index, and scalar column
  SHALL be removed
