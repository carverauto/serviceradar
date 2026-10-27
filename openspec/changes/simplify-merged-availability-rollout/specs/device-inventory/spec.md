## ADDED Requirements

### Requirement: Merged Availability Convergence On Upgrade
The system SHALL converge every deployment on merged device availability once, on upgrade, without an operator action and whatever staged-rollout mode (`legacy`, `shadow`, `cutover` or `authoritative`) it was in, and SHALL have no availability mode, mode control, readiness condition or shadow decision store afterwards.
Before the resolver takes `is_available` from the legacy writers, every device of a deployment in `legacy` or `shadow` that has no compatibility value SHALL get its current `is_available` as that value; an existing compatibility value SHALL NOT be overwritten. The system SHALL then resolve every live device once, rebuild the inventory counts, and, for a deployment that was not yet `authoritative`, publish one reconciliation summary whenever live devices exist, including zero differences, and, when transition events are on, a recovery event for each device the legacy value holds down and the merged state holds available. A device's first merged decision after the legacy mirror SHALL NOT emit a state-feed transition or a `device.*` event. Per-agent ledger rows SHALL NOT be changed by the convergence.

The internal `availability_settings.converged_at` timestamp SHALL be a one-time upgrade convergence marker, not an operator mode; nothing user-facing SHALL set or read it. The migration SHALL set it before dropping the mode function for authoritative deployments and installs with no device rows. Otherwise it SHALL remain NULL until the full resolve and rollup rebuild succeed. While NULL, every resolution path SHALL read NULL device provenance as the legacy mirror's projection of `is_available`, retaining the last boolean for unknown and suppressing the first transition. After it is set, new devices SHALL use normal first-decision behavior. Completion SHALL record an existing unhealthy `availability_cutover_readiness` check as healthy through HealthTracker, retaining history, and SHALL write nothing for absent or already healthy checks.

#### Scenario: Ordinary resolution precedes reconciliation
- **GIVEN** a legacy deployment with pre-capture devices carrying NULL provenance and true `is_available`
- **WHEN** ordinary resolution runs after migration but before reconciliation
- **THEN** the first merged decision SHALL emit no transition
- **AND** unknown SHALL retain true `is_available`
- **AND** after reconciliation sets the marker, a new device's first decisive result SHALL emit its normal transition

#### Scenario: Upgrade from legacy
- **GIVEN** a deployment in mode `legacy` whose Wi-Fi access point is held offline by failing sweeps while its controller reports it up
- **WHEN** the release that removes the staged rollout starts
- **THEN** the device badge, the device order and the Available count SHALL all read the device as available
- **AND** no per-device availability event SHALL be emitted for that first decision

#### Scenario: Upgrade from shadow
- **GIVEN** a deployment in mode `shadow`
- **WHEN** the release that removes the staged rollout starts
- **THEN** every live device SHALL carry a resolver decision
- **AND** the shadow decision store SHALL no longer exist

#### Scenario: Upgrade from authoritative
- **GIVEN** a deployment in mode `authoritative`
- **WHEN** the release that removes the staged rollout starts
- **THEN** no compatibility value SHALL change
- **AND** no reconciliation summary SHALL be published

#### Scenario: Fresh install
- **GIVEN** an empty database
- **WHEN** core starts for the first time
- **THEN** merged availability SHALL be in effect with no special handling
- **AND** no reconciliation summary SHALL be published

#### Scenario: Per-agent results are untouched
- **GIVEN** per-agent ledger rows, reachable, unreachable and stale, for upgraded devices
- **WHEN** the convergence runs
- **THEN** every row's value, checked time and failure counter SHALL be unchanged

## MODIFIED Requirements

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
- **GIVEN** merged device availability
- **WHEN** any code path other than the availability resolver changes `is_available` on a device row
- **THEN** the change SHALL be appended to an availability write-violation record
- **AND** the record SHALL NOT restore or reject the write; the device's next resolution sets the value again

### Requirement: Explicit Unknown Availability State
The system SHALL represent device availability as `available`, `unavailable` or `unknown`, and SHALL resolve `unknown` when no fresh, eligible record exists in any class.
`is_available` SHALL be `true` for `available` and `false` for `unavailable`, and SHALL keep its last decided value while the device is `unknown`; a device that has never had a decided state SHALL carry `false`. `unknown` SHALL be exposed only through `availability_state`, never as a NULL `is_available`. A device created without evidence SHALL start `unknown`.

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

## REMOVED Requirements

### Requirement: Staged Availability Cutover
**Reason**: The `legacy`/`shadow`/`cutover`/`authoritative` staging, its divergence report and its rollback were a development and validation process, not product behavior.
**Migration**: Upgrading converges the deployment once (Merged Availability Convergence On Upgrade). The compatibility store that legacy-semantics Armis sources read is kept.

### Requirement: Automatic Availability Progression
**Reason**: With no modes there is nothing to progress; the mode control, readiness conditions and the 24-hour readiness health warning are removed with them.
**Migration**: Upgrading converges the deployment once. The Helm value `core.availability.modeControl` is removed and ignored.
