## ADDED Requirements

### Requirement: Device Availability Evidence Contract
The system SHALL accept device availability only as evidence records submitted through a single core interface, and no availability source SHALL write `ocsf_devices.availability_state` or `ocsf_devices.is_available` directly.
Each evidence record carries the device uid, a source kind, a source instance, an optional reporter agent, an authority class, an observed state of `up` or `down`, an observed-at time, a freshness TTL, a confirmation count, a reporter-eligibility flag, and bounded detail. The system SHALL keep one current evidence record per device, source kind, source instance and reporter agent, separate from the device row.

#### Scenario: Controller and sweep evidence are kept separately
- **GIVEN** a device that a sweep agent probes and that a managing controller reports on
- **WHEN** the sweep reports the device down and the controller reports it up
- **THEN** the system SHALL store one evidence record for the sweep agent and one for the controller
- **AND** neither submission SHALL overwrite the other's record

#### Scenario: A source with no status submits no evidence
- **GIVEN** an integration row for a device that carries no operational status
- **WHEN** the integration is ingested
- **THEN** the integration SHALL NOT submit an availability evidence record for that device
- **AND** the device's availability SHALL be decided by the remaining evidence

#### Scenario: Direct writes do not change availability
- **GIVEN** the availability cutover is complete
- **WHEN** any code path other than the availability resolver attempts to change `is_available` or `availability_state` on a device row
- **THEN** the stored availability SHALL remain the resolver's value
- **AND** the attempt SHALL be appended to an availability write-violation record

### Requirement: Availability Authority Classes Are Declared By Source Registration
The system SHALL assign each evidence record an authority class taken from the submitting source's registration, and the resolver MUST NOT branch on a source's kind or integration name.
The ranked classes, highest first, are `operator_policy`, `self_report`, `managing_controller`, `active_probe`, `passive_observation` and `inventory_declared`. A source instance MAY lower the class its type declares but MUST NOT raise it. A source that declares no class SHALL be treated as `inventory_declared`. The classes `self_report` and `passive_observation` SHALL assert only `up`.

#### Scenario: New integration declares its class
- **GIVEN** a new integration type registered with authority class `managing_controller`
- **WHEN** it submits evidence for a device
- **THEN** the resolver SHALL rank that evidence as `managing_controller` without any code change to the resolver

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
The system SHALL derive each device's `availability_state` from its fresh, eligible, decisive evidence by selecting the highest-ranked authority class that has a decisive record and, within that class, resolving `available` when any decisive record is `up` and `unavailable` otherwise.
When the device has an `availability_source_agent_id` (set directly or by an availability source profile), `active_probe` evidence from other agents SHALL be excluded from the decision and retained for display. Evidence whose reporter is not eligible SHALL be excluded from the decision.

#### Scenario: Controller up outranks failing probes
- **GIVEN** a device with fresh `managing_controller` evidence `up`
- **AND** fresh, confirmed `active_probe` evidence `down` from two sweep agents
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available`
- **AND** the decision SHALL record `managing_controller` as the deciding class
- **AND** the device SHALL be marked as having conflicting lower-ranked evidence

#### Scenario: Any reachable vantage point wins within a class
- **GIVEN** a device with no evidence above `active_probe`
- **AND** fresh evidence `up` from one eligible sweep agent and confirmed `down` from another
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `available`

#### Scenario: Pinned agent decides the probe class
- **GIVEN** a device whose `availability_source_agent_id` is agent A
- **AND** fresh `active_probe` evidence `down` (confirmed) from agent A and `up` from agent B
- **AND** no evidence above `active_probe`
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `unavailable`
- **AND** agent B's evidence SHALL remain visible on the device

#### Scenario: Ineligible reporter does not decide
- **GIVEN** a sweep result from an agent that is not an expected reporter for the device's sweep group
- **WHEN** availability is resolved
- **THEN** that agent's evidence SHALL NOT affect `availability_state`

### Requirement: Availability Hysteresis Is Preserved
The system SHALL treat a `down` evidence record as decisive only after the number of consecutive `down` observations from that source reaches its authority class's confirmation threshold, and SHALL treat an `up` record as decisive immediately.
The `active_probe` threshold SHALL default to 2. The confirmation counter SHALL be capped at the threshold and SHALL NOT grow without bound.

#### Scenario: Single failed probe does not flip a device
- **GIVEN** a device resolved `available` from `active_probe` evidence
- **WHEN** its only eligible sweep agent reports one failed probe
- **THEN** `availability_state` SHALL remain `available`

#### Scenario: Second consecutive failure flips the device
- **GIVEN** the same device after one failed probe
- **WHEN** the agent reports a second consecutive failed probe
- **THEN** `availability_state` SHALL become `unavailable`

#### Scenario: Recovery is immediate
- **GIVEN** a device resolved `unavailable` from confirmed probe failures
- **WHEN** an eligible agent reports a successful probe
- **THEN** `availability_state` SHALL become `available` in the same ingestion

### Requirement: Availability Evidence Expires
The system SHALL ignore evidence whose freshness TTL has elapsed and SHALL re-resolve affected devices when evidence expires, without waiting for new evidence.
TTLs SHALL default per class from the source's cadence and SHALL be bounded by the source registration.

#### Scenario: Agent stops checking in
- **GIVEN** an agent host device whose only decisive evidence is `self_report` `up`
- **WHEN** the agent stops checking in and the evidence TTL elapses
- **THEN** the device SHALL be re-resolved from its remaining evidence
- **AND** if no other evidence exists its state SHALL become `unknown`

### Requirement: Explicit Unknown Availability State
The system SHALL represent device availability as `available`, `unavailable` or `unknown`, and SHALL resolve `unknown` when no fresh decisive evidence exists, except that pending, non-decisive `down` evidence SHALL keep the previous state.
After cutover, `is_available` SHALL be `true` for `available`, `false` for `unavailable` and `NULL` for `unknown`. A device created without evidence SHALL start `unknown`.

#### Scenario: Inventory-only device
- **GIVEN** a device imported by an inventory sync that reports no availability
- **WHEN** availability is resolved
- **THEN** `availability_state` SHALL be `unknown`
- **AND** `is_available` SHALL be NULL

#### Scenario: All evidence aged out
- **GIVEN** a device previously resolved `available`
- **WHEN** all of its evidence expires
- **THEN** `availability_state` SHALL be `unknown`
- **AND** the previous decision and its time SHALL remain inspectable

### Requirement: Availability Decision Provenance
The system SHALL record, with each device's availability, the deciding source kind, source instance, reporter agent, authority class and rule, the time the state last changed, and whether fresh lower-ranked evidence disagrees.

#### Scenario: Operator inspects why a device is available
- **GIVEN** a device resolved `available` by a managing controller while sweeps fail
- **WHEN** an operator reads the device
- **THEN** the device SHALL expose the controller as the deciding source with class `managing_controller`
- **AND** SHALL expose that conflicting evidence exists

### Requirement: Availability Writes Are Write-On-Change
The system SHALL write an evidence record only when its state changes, when its confirmation count is below the class threshold, or when its remaining lease is less than half its TTL, and SHALL write the device row only when the resolved state or its provenance changes.

#### Scenario: Steady unreachable device stops writing
- **GIVEN** a device resolved `unavailable` with confirmed probe failures
- **WHEN** further sweeps report the same failure within the lease
- **THEN** neither the evidence record nor the device row SHALL be rewritten

#### Scenario: Two sources disagree steadily
- **GIVEN** a device with controller evidence `up` and probe evidence `down`, both steady
- **WHEN** the controller sync and the sweep each run again
- **THEN** `availability_state` SHALL NOT change
- **AND** the device row SHALL NOT be rewritten

### Requirement: Availability Transitions Are Emitted Once By The Resolver
The system SHALL emit `device.available` and `device.unavailable` events and `signals.state.ocsf_devices` availability transitions only from the availability resolver, exactly once per resolved state change, after the resolving transaction commits.
Each transition SHALL name the deciding source kind, authority class, reporter agent and previous state. Emission of `device.*` events SHALL remain opt-in.

#### Scenario: One transition per real change
- **GIVEN** a device whose sweep and controller sources would previously have overwritten each other every cycle
- **WHEN** both sources keep reporting their steady values
- **THEN** no availability transition SHALL be emitted

#### Scenario: Rolled-back resolution emits nothing
- **GIVEN** a resolution transaction that fails after computing a state change
- **WHEN** the transaction rolls back
- **THEN** no availability event or state-feed transition SHALL be published

### Requirement: Availability Evidence Follows Device Identity Operations
The system SHALL move a merged-away device's evidence to the surviving device, keep the record with the later observed-at time on a collision, and re-resolve the survivor in the merge transaction. It SHALL also re-resolve a restored device in the restoring transaction without that re-resolution clearing any tombstone.

#### Scenario: Merge keeps fresher evidence
- **GIVEN** two devices with evidence from the same sweep agent
- **AND** the device being merged away holds the more recent observation
- **WHEN** the devices are merged
- **THEN** the survivor SHALL keep the more recent observation
- **AND** the survivor's availability SHALL be re-resolved

### Requirement: Staged Availability Cutover
The system SHALL support availability modes `legacy`, `shadow` and `authoritative`. In `shadow` mode it SHALL publish a divergence report before any device's canonical availability is decided by the resolver.
The report SHALL count devices by legacy value, legacy badge value, shadow state, deciding source kind and authority class, and SHALL include sample device uids. Entering `authoritative` mode SHALL apply the shadow decisions through a reconciliation pass that suppresses per-device transition events, state-feed messages and UI invalidations and emits one summary event. Returning to `legacy` SHALL restore the legacy writers.

#### Scenario: Shadow mode changes nothing visible
- **GIVEN** availability mode `shadow`
- **WHEN** evidence is ingested and resolved
- **THEN** `ocsf_devices.is_available` SHALL still be written only by the legacy writers
- **AND** the shadow decision SHALL be stored separately

#### Scenario: Cutover does not storm
- **GIVEN** a shadow report showing many devices that would change state
- **WHEN** the mode is switched to `authoritative`
- **THEN** the reconciliation SHALL apply all changes without emitting per-device `device.available` or `device.unavailable` events
- **AND** SHALL emit one summary event with the counts per resulting state

#### Scenario: Rollback to legacy
- **GIVEN** availability mode `authoritative`
- **WHEN** an operator switches the mode back to `legacy`
- **THEN** the legacy writers SHALL resume writing `is_available` on their next cycle
- **AND** stored evidence SHALL be retained
