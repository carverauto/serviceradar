## ADDED Requirements

### Requirement: Native add-on approval is separate from desired version
The control plane SHALL keep package approval separate from native add-on desired
state. Importing or approving a package SHALL NOT directly rewrite assignment or
profile package IDs in the approval transaction. Managed sources MAY consume that
approval asynchronously by creating a rollout; manual pins SHALL remain unchanged.

#### Scenario: Approval does not update a manual pin
- **GIVEN** an agent or profile pinned to approved add-on version `0.2.22`
- **AND** version `0.2.23` is imported and approved
- **WHEN** the source update policy is `manual_pin`
- **THEN** its desired package SHALL remain version `0.2.22`
- **AND** no agent config change or deployment SHALL be triggered by approval alone

#### Scenario: Existing first-party source becomes managed
- **GIVEN** a direct assignment or add-on profile created before update policies exist
- **AND** its current package is signed, verified, and has `first_party` provenance
- **AND** the source does not carry an explicit operator pin
- **WHEN** the update-policy migration runs
- **THEN** the source SHALL be assigned `track_latest_approved`
- **AND** its selected package, params, enablement, and target scope SHALL remain unchanged

#### Scenario: Existing non-first-party source remains pinned
- **GIVEN** a direct assignment or add-on profile created before update policies exist
- **AND** its current package came from upload, GitHub, or unverifiable provenance
- **WHEN** the update-policy migration runs
- **THEN** the source SHALL be assigned `manual_pin`
- **AND** its selected package, params, enablement, and target scope SHALL remain unchanged

### Requirement: Latest-approved tracking is provenance-aware and eligibility constrained
The control plane SHALL support `track_latest_approved` on direct assignments and
add-on profiles and SHALL default signed, verified first-party sources to that policy.
Non-first-party sources SHALL default to `manual_pin`, and an explicit operator pin
SHALL take precedence over provenance defaults. Tracking SHALL consider only newer
signed, verified, approved, non-revoked packages for the same logical add-on and
trusted lineage on the selected release channel that satisfy platform, agent-contract,
and capability-ceiling constraints. Finding a candidate SHALL create a rollout rather
than rewriting all desired state.

#### Scenario: Opted-in profile discovers an eligible candidate
- **GIVEN** a profile on `track_latest_approved` with stable version `0.2.22`
- **AND** version `0.2.23` is approved, compatible, and within the policy's capability ceiling
- **WHEN** latest-candidate reconciliation runs
- **THEN** the control plane SHALL create a rollout from `0.2.22` to `0.2.23`
- **AND** profile-derived assignments SHALL remain on the stable package until their rollout targets advance

#### Scenario: First-party source tracks without package-by-package operator action
- **GIVEN** a source using a signed, verified first-party package on `track_latest_approved`
- **AND** a newer package for the same add-on is approved by manual review or the configured auto-approval allowlist
- **WHEN** latest-candidate reconciliation runs
- **THEN** the control plane SHALL create and start a health-gated rollout automatically
- **AND** an operator SHALL NOT need to edit the assignment or profile package ID

#### Scenario: Candidate cannot expand privilege silently
- **GIVEN** a track-latest source whose capability ceiling excludes `host_network_admin`
- **AND** a newer approved package requires that capability
- **WHEN** latest-candidate reconciliation runs
- **THEN** the candidate SHALL be blocked for that source
- **AND** no rollout target or desired-state override SHALL be activated until an authorized operator changes the policy

#### Scenario: Active rollout serializes newer candidates
- **GIVEN** a source already rolling from version `0.2.22` to `0.2.23`
- **AND** version `0.2.24` becomes approved
- **WHEN** latest-candidate reconciliation runs
- **THEN** a second rollout SHALL NOT overlap the active source or effective targets
- **AND** version `0.2.24` SHALL be reconsidered after the active rollout reaches a terminal state

### Requirement: Native add-on rollouts are snapshotted and batched
The control plane SHALL roll a candidate package to a snapshotted eligible target set
through a canary and bounded batches. Each rollout SHALL persist its source provenance,
previous and candidate packages, target classification, canary size, batch size,
maximum parallelism, soak duration, health timeout, tolerated failures, lifecycle
state, and per-target transitions. It SHALL support pause, resume, and cancel without
advancing new targets while paused or canceled.

#### Scenario: Canary advances without changing every profile target
- **GIVEN** a profile whose target query currently resolves to 100 eligible agents
- **AND** a rollout configured with one canary and batches of ten
- **WHEN** the rollout starts
- **THEN** exactly the canary target SHALL receive the candidate desired-state override
- **AND** the other 99 targets SHALL continue receiving the profile's stable package

#### Scenario: Target snapshot records exclusions
- **GIVEN** selected agents that include compatible, incompatible, directly overridden, unavailable, and unresolved targets
- **WHEN** a rollout preview is accepted
- **THEN** the rollout SHALL snapshot each target and its classification/reason
- **AND** only compatible eligible targets SHALL enter delivery batches

#### Scenario: Pause prevents the next batch
- **GIVEN** a rollout whose current batch has reached a terminal state
- **WHEN** an authorized operator pauses the rollout before the next batch advances
- **THEN** no additional target SHALL receive the candidate desired-state override
- **AND** current per-target state and evidence SHALL remain available for resume or rollback

### Requirement: Native add-on rollout gates use fresh model-specific health
A rollout target SHALL pass only from status evidence observed after its candidate
desired state became effective, matching the candidate version and the package's
supervision-specific readiness contract for the configured soak period. Stale or
pre-rollout status SHALL NOT satisfy a gate. A failed target SHALL restore its previous
desired package and params, and a gate failure SHALL stop advancement before the next
batch.

#### Scenario: Continuous service passes after healthy soak
- **GIVEN** a `systemd-service` target advanced to version `0.2.23`
- **WHEN** it reports version `0.2.23` installed, active, and healthy after the target advance
- **AND** that state remains fresh for the configured soak period
- **THEN** the target SHALL pass its health gate

#### Scenario: Dormant ephemeral helper is ready
- **GIVEN** an `ephemeral-helper` target advanced to version `0.3.1`
- **WHEN** it reports version `0.3.1` verified, staged, and registered for invocation
- **AND** there is no active invocation
- **THEN** the target SHALL pass its readiness gate without being continuously active

#### Scenario: Stale status cannot pass a gate
- **GIVEN** a target whose last healthy status predates its candidate desired-state override
- **WHEN** its health gate is evaluated
- **THEN** the target SHALL remain pending rather than pass
- **AND** it SHALL fail as unavailable if no fresh evidence arrives before its deadline

#### Scenario: Failed target rolls back and halts advancement
- **GIVEN** a target that reports artifact verification failure for the candidate package
- **WHEN** its health gate evaluates the failure
- **THEN** the control plane SHALL restore the target's previous desired package and params
- **AND** SHALL pause the rollout before advancing another batch
- **AND** SHALL record rollback recovery from fresh status evidence

#### Scenario: Successful rollout promotes authoritative state
- **GIVEN** every required rollout target for a profile has passed its gate
- **WHEN** the rollout completes
- **THEN** the profile's stable package SHALL be promoted to the candidate package
- **AND** per-target rollout overrides SHALL be removed
- **AND** agents newly matching the profile SHALL receive the promoted stable package on reconciliation

### Requirement: Profile reconciliation outcomes remain observable during invalid desired state
The control plane SHALL persist the latest add-on profile reconciliation outcome
without rerunning package approval or configuration validation on the outcome-only
write. Desired-state validation SHALL continue to protect profile configuration
changes, while a failed reconcile SHALL remain visible even when its selected
package is staged, denied, or revoked.

#### Scenario: Staged package blocks assignment materialization
- **GIVEN** an add-on profile references a package that is no longer approved
- **WHEN** profile reconciliation fails before materializing its desired assignments
- **THEN** the profile SHALL retain its existing desired configuration unchanged
- **AND** its latest reconciliation summary SHALL record the failure and timestamp
- **AND** recording that outcome SHALL NOT itself fail package approval validation
