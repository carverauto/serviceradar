## ADDED Requirements

### Requirement: Per-Agent Availability Ledger Is Lossless
The system SHALL keep, for every device and every agent that probes it, that agent's own latest reachability result (available or not) with its own check timestamp, and the merged device availability MUST NOT prune, age out, overwrite or reinterpret those per-agent rows.
The merged availability is a summary derived from the per-agent ledger and the other evidence. A stale per-agent row SHALL remain stored and readable with its original value and timestamp.

#### Scenario: Blocked agent result is retained
- **GIVEN** agent A reaches a device and agent B does not
- **WHEN** the device's merged availability is resolved as available
- **THEN** agent B's latest result SHALL remain stored as not available with its own check time
- **AND** agent A's latest result SHALL remain stored as available with its own check time

#### Scenario: Stale agent result is not deleted
- **GIVEN** an agent stops probing a device
- **WHEN** that agent's latest result becomes older than its freshness window
- **THEN** the result SHALL remain stored unchanged
- **AND** the merged availability SHALL ignore it as stale

### Requirement: Device Availability Evidence Contract
The system SHALL accept non-probe availability (controllers, hypervisors, camera managers, agent liveness, passive sightings, plugins, inventory records and operator policy) only as evidence records submitted through a single core interface, and no availability source SHALL write `ocsf_devices.availability_state` or `ocsf_devices.is_available` directly.
Each evidence record carries the device uid, a source kind, a source instance, an optional reporter agent, an authority class, an observed state of `up` or `down`, an observed-at time, a freshness TTL, a confirmation count, a reporter-eligibility flag, and bounded detail. The system SHALL keep one current evidence record per device, source kind, source instance and reporter agent. Agent reachability probes SHALL be read from the per-agent ledger and SHALL NOT be duplicated into the evidence store.

#### Scenario: Controller and sweep evidence are kept separately
- **GIVEN** a device that a sweep agent probes and that a managing controller reports on
- **WHEN** the sweep reports the device unreachable and the controller reports it up
- **THEN** the sweep result SHALL be stored in the per-agent ledger and the controller observation SHALL be stored as an evidence record
- **AND** neither SHALL overwrite the other

#### Scenario: A source with no status submits no evidence
- **GIVEN** an integration row for a device that carries no operational status
- **WHEN** the integration is ingested
- **THEN** the integration SHALL NOT submit an availability evidence record for that device

#### Scenario: Direct writes are recorded, never silently restored
- **GIVEN** the availability cutover is complete
- **WHEN** any code path other than the availability resolver changes `is_available` on a device row
- **THEN** the change SHALL be appended to an availability write-violation record
- **AND** the record SHALL NOT restore or reject the write; the device's next resolution sets the value again

### Requirement: Availability Authority Classes Are Declared By Source Registration
The system SHALL assign each evidence record an authority class taken from the submitting source's registration, and the resolver MUST NOT branch on a source's kind or integration name.
The ranked classes, highest first, are `operator_policy`, `self_report`, `managing_controller`, `active_probe`, `passive_observation` and `inventory_declared`; the per-agent ledger is `active_probe`. A source instance MAY lower the class its type declares but MUST NOT raise it. A source that declares no class SHALL be treated as `inventory_declared`. The classes `self_report` and `passive_observation` SHALL assert only `up`.

#### Scenario: New integration declares its class
- **GIVEN** a new integration type registered with authority class `managing_controller`
- **WHEN** it submits evidence for a device
- **THEN** the resolver SHALL rank that evidence as `managing_controller` without any change to the resolver

#### Scenario: Static import is lowered to declared inventory
- **GIVEN** an integration type that declares `managing_controller`
- **AND** an instance of it configured as a static file import with class `inventory_declared`
- **WHEN** the instance submits evidence
- **THEN** the evidence SHALL carry `inventory_declared`

#### Scenario: Undeclared source ranks lowest
- **GIVEN** a source with no declared authority class
- **WHEN** it submits evidence
- **THEN** the evidence SHALL carry `inventory_declared`

### Requirement: Canonical Device Availability Resolution
The system SHALL derive each device's `availability_state` by selecting the governing class (the highest-ranked authority class with any fresh, eligible, non-excluded record), deciding from that class when it has a decisive record and keeping the previous state when it has only records awaiting confirmation; within the deciding class the state SHALL be `available` when any decisive record is `up` and `unavailable` otherwise.
When the device has an `availability_source_agent_id` (set directly or by an availability source profile), per-agent results from other agents and `operator_policy` evidence SHALL be excluded from the decision and retained for display; the per-device pin outranks operator policy, and an excluded record that disagrees SHALL mark the device as having conflicting evidence. Records whose reporter is not eligible, and unreachable per-agent results from negative-control agents, SHALL be excluded from the decision. A cross-class `up` from a lower class SHALL NOT override a higher class's decision; it SHALL mark the device as having conflicting evidence. The previously deciding record SHALL remain the recorded decider while it stays fresh, eligible and in agreement.
Every mutation that can change a resolution SHALL cause the affected devices to be re-resolved through the same resolver without waiting for expiry: per-agent ledger writes from any writer that change a result or renew one older than half its freshness window, changes to a device's `availability_source_agent_id` or to an availability source profile, and changes to negative-control vantage expectations. Recording such a mutation SHALL be an append that never waits on the resolver or on another writer, and an invalidation committed while a device is being resolved SHALL cause one more resolution of that device.

#### Scenario: Controller up outranks failing probes
- **GIVEN** a device with fresh `managing_controller` evidence `up`
- **AND** confirmed unreachable results from two sweep agents
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available` decided by `managing_controller`
- **AND** the device SHALL be marked as having conflicting evidence

#### Scenario: Any reachable vantage point wins within a class
- **GIVEN** a device with no evidence above `active_probe`
- **AND** a fresh reachable result from one eligible agent and a confirmed unreachable result from another
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available`

#### Scenario: Pinned agent decides the probe class
- **GIVEN** a device whose `availability_source_agent_id` is agent A
- **AND** a confirmed unreachable result from agent A and a reachable result from agent B
- **AND** no evidence above `active_probe`
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `unavailable`
- **AND** agent B's result SHALL remain visible on the device

#### Scenario: Pin outranks operator policy
- **GIVEN** a device whose `availability_source_agent_id` is agent A
- **AND** a reachable result from agent A
- **AND** fresh `operator_policy` evidence `down` from a composite check
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available` decided by agent A
- **AND** the device SHALL be marked as having conflicting evidence

#### Scenario: Changing the pin re-resolves the device
- **GIVEN** a device resolved `available` from agent B's reachable result while agent A reports it confirmed unreachable
- **WHEN** an operator sets the device's `availability_source_agent_id` to agent A
- **THEN** the device SHALL be re-resolved `unavailable` without new evidence

#### Scenario: Ineligible reporter does not decide
- **GIVEN** a sweep result from an agent that is not an expected reporter for the device's sweep group
- **WHEN** availability is resolved
- **THEN** that agent's result SHALL NOT affect `availability_state`

### Requirement: Negative-Control Vantage Points
The system SHALL treat an agent that an enabled composite check expects to be blocked for a device as a negative-control vantage point for that device. An unreachable result from that agent SHALL be excluded from the merged availability decision and counted as a verified block. A reachable result SHALL count as liveness in the decision and SHALL be counted as a policy violation.
The policy-violation signal SHALL be the composite check's existing verdict and verdict events, and the merged availability SHALL NOT emit a second event for it.

#### Scenario: Expected block does not pull the device down
- **GIVEN** agent A is a liveness witness and agent B is expected to be blocked for a device
- **AND** agent A reaches the device and agent B does not
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available`
- **AND** the device SHALL report one verified block and no policy violation

#### Scenario: Should-be-blocked agent reaches the device
- **GIVEN** agent B is expected to be blocked for a device
- **AND** agent B reaches the device
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available` unless a higher authority class decides otherwise
- **AND** the device SHALL report a policy violation
- **AND** the composite check's verdict for the device SHALL be unchanged by this resolution

#### Scenario: New negative-control expectation re-resolves the device
- **GIVEN** a device resolved `unavailable` from agent B's confirmed unreachable result and no other fresh evidence
- **WHEN** an enabled composite check starts expecting agent B to be blocked for the device
- **THEN** the device SHALL be re-resolved without new evidence
- **AND** agent B's result SHALL be counted as a verified block and not as `unavailable`

### Requirement: Availability Hysteresis Is Preserved
The system SHALL treat a `down` record as decisive only after the number of consecutive `down` observations from that source reaches its authority class's confirmation threshold, SHALL treat an `up` record as decisive immediately, and SHALL keep a device's previous state while its governing class holds only records awaiting confirmation.
The `active_probe` threshold SHALL default to 2. The confirmation counter SHALL be stored on the per-agent ledger row or evidence record, capped at the threshold. The per-agent counter SHALL be maintained at the ledger write boundary for every ledger writer, SHALL advance only for an observation newer than the stored one, and SHALL NOT change the stored result or its timestamps.

#### Scenario: Single failed probe does not flip a device
- **GIVEN** a device resolved `available` from per-agent results
- **WHEN** its only eligible agent reports one failed probe
- **THEN** `availability_state` SHALL remain `available`

#### Scenario: Pending failure does not fall through to a lower class
- **GIVEN** a device resolved `available` from a reachable agent result
- **AND** fresh `inventory_declared` evidence `down`
- **WHEN** the agent reports its first failed probe
- **THEN** `availability_state` SHALL remain `available`

#### Scenario: Second consecutive failure flips the device
- **GIVEN** the same device after one failed probe
- **WHEN** the agent reports a second consecutive failed probe
- **THEN** `availability_state` SHALL become `unavailable`

#### Scenario: Validation-only witness is confirmed like a sweep agent
- **GIVEN** a device resolved `available` whose only eligible agent result comes from validation scans
- **WHEN** two consecutive validation scans from that agent report it unreachable
- **THEN** that agent's counter SHALL reach the threshold
- **AND** `availability_state` SHALL become `unavailable` without waiting for the result to expire

#### Scenario: Reassigning a ledger row does not count a failure
- **GIVEN** an agent result with one recorded failure
- **WHEN** the row is moved to a merge survivor without a new observation
- **THEN** its failure count and check time SHALL be unchanged

#### Scenario: Recovery is immediate
- **GIVEN** a device resolved `unavailable` from confirmed probe failures
- **WHEN** an eligible agent reports a successful probe
- **THEN** `availability_state` SHALL become `available` in the same ingestion

### Requirement: Availability Evidence Expires
The system SHALL ignore evidence and per-agent results older than their freshness window when resolving availability, and SHALL re-resolve affected devices when they expire without waiting for new evidence.
TTLs SHALL default per class from the source's cadence and SHALL be bounded by the source registration.

#### Scenario: Agent stops checking in
- **GIVEN** an agent host device whose only decisive evidence is `self_report` `up`
- **WHEN** the agent stops checking in and the evidence TTL elapses
- **THEN** the device SHALL be re-resolved from its remaining evidence
- **AND** if no other evidence exists its state SHALL become `unknown`

### Requirement: Explicit Unknown Availability State
The system SHALL represent device availability as `available`, `unavailable` or `unknown`, and SHALL resolve `unknown` when no fresh, eligible record exists in any class.
After cutover, `is_available` SHALL be `true` for `available` and `false` for `unavailable`, and SHALL keep its last decided value while the device is `unknown`; a device that has never had a decided state SHALL carry `false`. `unknown` SHALL be exposed only through `availability_state`, never as a NULL `is_available`. A device created without evidence SHALL start `unknown`.

#### Scenario: Inventory-only device
- **GIVEN** a device imported by an inventory sync that reports no availability
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `unknown`
- **AND** `is_available` SHALL be `false`

#### Scenario: All evidence aged out
- **GIVEN** a device previously resolved `available`
- **WHEN** all of its evidence and per-agent results expire
- **THEN** `availability_state` SHALL be `unknown`
- **AND** `is_available` SHALL remain `true`
- **AND** the previous decision and its time SHALL remain inspectable

### Requirement: Availability Decision Provenance And Agent Summary
The system SHALL record, with each device's availability, the deciding source kind, source instance, reporter agent, authority class and rule, the time the state last changed, whether fresh excluded or lower-ranked evidence disagrees, and a per-agent summary counting reachable, unreachable, stale and total non-control agents plus verified blocks, policy violations and inconclusive negative controls.

#### Scenario: Operator inspects why a device is available
- **GIVEN** a device resolved `available` by a managing controller while sweeps fail
- **WHEN** an operator reads the device
- **THEN** the device SHALL expose the controller as the deciding source with class `managing_controller`
- **AND** SHALL expose that conflicting evidence exists
- **AND** SHALL expose that zero of its probing agents reach it

### Requirement: Availability Writes Are Write-On-Change
The system SHALL write an evidence record only when its state, authority class, reporter eligibility or effective expiry changes, when its confirmation count is below the class threshold, or when its remaining lease is less than half its TTL, and SHALL write the device row only when the resolved state, provenance, conflict flag or per-agent summary changes.

#### Scenario: Steady disagreement stops writing
- **GIVEN** a device with controller evidence `up` and confirmed unreachable agent results, both steady
- **WHEN** the controller sync and the sweep each run again within the lease
- **THEN** neither the evidence record nor the device row SHALL be rewritten

#### Scenario: Eligibility change is written immediately
- **GIVEN** an evidence record whose reporter becomes ineligible
- **WHEN** the source submits the same state within the lease
- **THEN** the evidence record SHALL be rewritten with the new eligibility
- **AND** the device SHALL be re-resolved

#### Scenario: Conflict change updates the device without a transition
- **GIVEN** a device resolved `available` by a controller with no conflict
- **WHEN** a probing agent's failures reach the confirmation threshold
- **THEN** the device's conflict flag and agent summary SHALL be updated
- **AND** no availability transition SHALL be emitted

### Requirement: Availability Transitions Are Emitted Once By The Resolver
The system SHALL emit `device.available` and `device.unavailable` events and `signals.state.ocsf_devices` availability transitions only from the availability resolver, exactly once per change of `availability_state`, after the resolving transaction commits.
Each transition SHALL name the deciding source kind, authority class, reporter agent and previous state. Emission of `device.*` events SHALL remain opt-in.

#### Scenario: One transition per real change
- **GIVEN** a device whose sweep and controller sources would previously have overwritten each other every cycle
- **WHEN** both sources keep reporting their steady values
- **THEN** no availability transition SHALL be emitted

#### Scenario: Rolled-back resolution emits nothing
- **GIVEN** a resolution transaction that fails after computing a state change
- **WHEN** the transaction rolls back
- **THEN** no availability event or state-feed transition SHALL be published

### Requirement: Availability Follows Device Identity Operations
The system SHALL move a merged-away device's evidence records to the surviving device and re-resolve the survivor in the merge transaction, SHALL leave per-agent ledger reassignment behavior unchanged, and SHALL re-resolve a restored device in the restoring transaction without that re-resolution clearing any tombstone.

#### Scenario: Merge does not wait on background resolution
- **GIVEN** a merge transaction that holds the surviving device's lock and reassigns per-agent results
- **AND** background resolution is waiting for the same device
- **WHEN** both run
- **THEN** the merge SHALL commit without waiting on background resolution
- **AND** background resolution SHALL then resolve the survivor from the merged inputs

#### Scenario: Merge re-resolves the survivor
- **GIVEN** two devices with availability evidence
- **WHEN** they are merged
- **THEN** the survivor SHALL hold both devices' evidence records
- **AND** the survivor's availability SHALL be re-resolved before the merge commits

### Requirement: Staged Availability Cutover
The system SHALL support availability modes `legacy`, `shadow`, `cutover` and `authoritative`, SHALL drain writers admitted under the mode-switch lock on every mode change, and SHALL publish a divergence report in `shadow` mode before any device's canonical availability is decided by the resolver.
The report SHALL count devices by legacy value, legacy badge value, shadow state, deciding source kind and authority class, SHALL count devices that would become unknown, policy violations and invalid pins, SHALL include per-source Armis northbound push changes, and SHALL include sample device uids. In `legacy` and `shadow` modes `availability_state` SHALL equal the projection of `is_available`, and the legacy transition publishers SHALL emit. Until the legacy writers are removed they SHALL maintain the legacy availability value in a compatibility store in every mode, and that store SHALL be seeded from `is_available` under the drained cutover boundary. In `cutover` mode a legacy writer admitted under the shared lock SHALL NOT write device availability. An agent check-in reads the mode without that lock (`LegacyWrites`). Every availability transition side effect SHALL be suppressed while reconciliation re-resolves every device from its current evidence under the device lock; `authoritative` mode SHALL begin only after reconciliation completes. Returning to `legacy` SHALL restore `is_available` from the compatibility store and the legacy writers and publishers.

#### Scenario: Shadow mode changes nothing visible
- **GIVEN** availability mode `shadow`
- **WHEN** evidence is ingested and resolved
- **THEN** `ocsf_devices.is_available` SHALL still be written only by the legacy writers
- **AND** `availability_state` SHALL equal the projection of `is_available`
- **AND** the shadow decision SHALL be stored separately

#### Scenario: Cutover does not storm
- **GIVEN** a shadow report showing many devices that would change state
- **WHEN** the mode is switched to `cutover` and reconciliation runs while ingestion continues
- **THEN** no per-device `device.available` or `device.unavailable` event and no state-feed transition SHALL be emitted until the mode becomes `authoritative`
- **AND** one summary event with the counts per resulting state SHALL be emitted
- **AND** no legacy writer admitted under the shared lock SHALL change a reconciled device's availability

#### Scenario: Reconciliation does not restore a superseded decision
- **GIVEN** a shadow decision of `available` for a device
- **AND** ingestion in `cutover` mode records confirmed `down` evidence and resolves the device `unavailable`
- **WHEN** reconciliation reaches the device
- **THEN** the device SHALL remain `unavailable`

#### Scenario: Rollback to legacy
- **GIVEN** availability mode `authoritative`
- **WHEN** the mode is switched back to `legacy`, by the `hold_legacy` mode control or by a support switch
- **THEN** `is_available` SHALL be restored from the compatibility store
- **AND** `availability_state` SHALL equal the projection of the restored `is_available`
- **AND** the legacy writers and legacy transition publishers SHALL resume
- **AND** stored evidence and per-agent results SHALL be retained

### Requirement: Automatic Availability Progression
The system SHALL move the availability mode from `legacy` to `shadow`, and from `shadow` through `cutover` to `authoritative`, without an operator action, under a deployment mode control whose default is `auto`, and SHALL make each step through the same mode switches an operator uses.
Under `auto`, the system SHALL enter `cutover` only when every readiness condition holds: the capture backfill has nothing left; a full shadow resolution that started after entering `shadow` has finished; at most one resolver pass of invalidation entries (500) is waiting; every active sweep group (enabled, and started by an agent in the last 24 hours) has completed a run, per agent, that started after entering `shadow`; and the divergence report counts no policy violation. The system SHALL record the last readiness evaluation, naming each unmet condition, and while any condition is unmet 24 hours after entering `shadow` SHALL stay in `shadow` and record an unhealthy core health check naming the unmet conditions. A later run SHALL record that check healthy when the deployment is no longer in that stall and the check is already unhealthy, and SHALL write no health row for it otherwise. The control `hold_legacy` SHALL keep or roll back to `legacy`, restoring `is_available` from the compatibility store when leaving `cutover` or `authoritative`. The control `hold_shadow` SHALL keep or return to `shadow` and SHALL NOT cut over; from `cutover` or `authoritative` it SHALL roll back to `legacy` first and enter `shadow` only after the restore has finished. When the compatibility snapshot still differs and no restore is waiting, it SHALL enqueue the restore again and SHALL NOT enter `shadow`. A control pinned by deployment configuration SHALL take precedence over the stored control, the stored control SHALL NOT be editable while a pin is recorded, and a pinned value that is not a control SHALL hold the mode where it is. Runs on several nodes SHALL NOT switch twice, and a run SHALL NOT switch from a control that changed after it was read. The automatic cutover SHALL NOT emit per-device transitions, and SHALL NOT change any Armis northbound source's semantics.

#### Scenario: An install whose conditions hold reaches authoritative unattended
- **GIVEN** an install in `legacy` with the control `auto`
- **AND** devices, and an enabled sweep group whose agent completed a run after the install entered `shadow`
- **WHEN** the progression runs and the full shadow resolution finishes
- **THEN** the mode SHALL become `shadow`, then `cutover`, then `authoritative` with no operator action
- **AND** the reconciliation SHALL publish one summary event and no per-device transition

#### Scenario: A zero-device install reaches authoritative
- **GIVEN** an install with no devices and no enabled sweep group, in `legacy` with the control `auto`
- **WHEN** the progression runs and the full shadow resolution over zero devices finishes
- **THEN** the mode SHALL reach `authoritative` through the same steps

#### Scenario: Each unmet condition blocks the cutover and is named
- **GIVEN** a deployment in `shadow` with the control `auto` and exactly one readiness condition unmet
- **WHEN** the progression runs
- **THEN** the mode SHALL stay `shadow`
- **AND** the recorded readiness evaluation SHALL name that condition as unmet

#### Scenario: A sweep run before the shadow entry does not count
- **GIVEN** an enabled sweep group whose agent last completed a run before the deployment entered `shadow`
- **WHEN** the progression evaluates readiness
- **THEN** the sweep-group condition SHALL be unmet until that agent completes a run started after the entry

#### Scenario: Unmet conditions after 24 hours raise a health warning
- **GIVEN** a deployment that entered `shadow` more than 24 hours ago with a readiness condition still unmet
- **WHEN** the progression runs
- **THEN** the mode SHALL stay `shadow`
- **AND** the core health check for availability readiness SHALL be unhealthy and name the unmet condition
- **AND** a later run SHALL record the check healthy when the stall no longer holds and the check is already unhealthy
- **AND** a deployment that never raised the check SHALL get no health row for it

#### Scenario: hold_legacy rolls back an authoritative deployment
- **GIVEN** an `authoritative` deployment where a device's merged value differs from its legacy value
- **WHEN** the control is set to `hold_legacy`
- **THEN** the mode SHALL become `legacy`
- **AND** the device's `is_available` SHALL be restored from the compatibility store
- **AND** later runs SHALL leave the mode `legacy`

#### Scenario: hold_shadow returns an authoritative deployment to shadow
- **GIVEN** an `authoritative` deployment
- **WHEN** the control is set to `hold_shadow`
- **THEN** the mode SHALL become `legacy`, SHALL NOT enter `shadow` while the restore is outstanding, and SHALL enter `shadow` after it finished
- **AND** when that restore is gone and the snapshot still differs, a later run SHALL enqueue it again and SHALL NOT enter `shadow`
- **AND** the mode SHALL stay `shadow` even when every readiness condition holds

#### Scenario: A pin overrides the stored control
- **GIVEN** a stored control of `hold_shadow` and a pinned control of `hold_legacy`
- **WHEN** the progression runs in `shadow`
- **THEN** the mode SHALL become `legacy`
- **AND** the pin SHALL be recorded on the settings row
- **AND** an attempt to edit the stored control SHALL be refused

#### Scenario: An invalid pin holds the mode
- **GIVEN** a pinned value that is not `auto`, `hold_legacy` or `hold_shadow`
- **WHEN** the progression runs
- **THEN** the mode SHALL NOT change

#### Scenario: A refused support switch keeps the hold
- **GIVEN** a deployment in `legacy` under `hold_legacy`
- **WHEN** a support switch to `cutover` is refused because the mode is not `shadow`
- **THEN** the stored control SHALL remain `hold_legacy`
- **AND** the progression SHALL leave the mode `legacy`

#### Scenario: Concurrent runs switch once
- **GIVEN** two progression runs that both read `authoritative` under `hold_legacy`
- **WHEN** both switch
- **THEN** the mode SHALL be switched to `legacy` once
- **AND** the restore the first switch enqueued SHALL remain enqueued
