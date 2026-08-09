## ADDED Requirements

### Requirement: Superseded add-on rollouts terminate instead of lingering

An add-on rollout SHALL resolve as superseded when every in-scope target already
reports the candidate version as its observed version, regardless of how the
targets reached it. Superseded rollouts SHALL be terminal: they are not paused,
not resumable, and not counted as outstanding work.

Convergence reached outside the rollout -- a later rollout, a direct assignment,
a reinstall, or an operator action on the host -- SHALL satisfy this the same
way convergence driven by the rollout does, because the reaper reads observed
fleet state rather than the rollout's own batch progress.

#### Scenario: Paused rollout whose candidate the fleet already runs

- **GIVEN** a rollout of `bumblebee` from `0.1.1` to `0.1.2` is `paused`
- **AND** every in-scope agent reports observed version `0.1.2`
- **WHEN** rollout state is next evaluated
- **THEN** the rollout resolves as superseded
- **AND** it no longer appears as an active rollout
- **AND** it offers no resume, roll back, or cancel action

#### Scenario: Fleet has moved past the candidate version

- **GIVEN** a rollout of `workload-identity` from `0.1.4` to `0.1.5` is `paused`
- **AND** in-scope agents report observed versions `0.1.5` and `0.1.7`
- **WHEN** rollout state is next evaluated
- **THEN** the rollout resolves as superseded
- **AND** agents already past the candidate version are not rolled back to it

#### Scenario: Partially converged rollout is left alone

- **GIVEN** a rollout of `scalibr-endpoint-inventory` from `0.1.1` to `0.1.3`
- **AND** in-scope agents report observed version `0.1.2`
- **WHEN** rollout state is next evaluated
- **THEN** the rollout is NOT resolved as superseded
- **AND** its existing state and blocked reason are preserved

### Requirement: Add-on rollout health gating separates candidate faults from environment faults

Rollout health gating SHALL block only on faults attributable to the candidate
build. A reported fault that is a property of the host or of absent upstream
input SHALL NOT pause a rollout. Such a fault SHALL still be surfaced on the
fleet row and recorded on the rollout as an advisory, so that suppressing the
gate never suppresses the signal.

Classification SHALL be derived from the reported status itself, not from a
per-add-on allowlist, so a new add-on inherits the behaviour without being
enumerated.

A reported status SHALL be treated as a candidate fault when the add-on is not
running -- process absent, unit failed, crash looping, or its control interface
unreachable. A reported status SHALL be treated as an environment fault when the
add-on is running and the reported degradation describes a missing external
dependency or an unenforceable host resource policy.

#### Scenario: Missing upstream input does not block the rollout

- **GIVEN** `powerdns` is `running` on every in-scope agent
- **AND** each agent reports `no PowerDNS Recursor protobuf producer connected`
- **WHEN** a rollout from `0.1.3` to `0.1.4` evaluates candidate health
- **THEN** the rollout is not paused for that reason
- **AND** the rollout records the reported reason as an advisory
- **AND** the fleet row for `powerdns` continues to show the reported reason

#### Scenario: Unenforceable host resource policy does not block the rollout

- **GIVEN** `anomaly` is `running` on every in-scope agent
- **AND** each agent reports `resource limits not enforced` for the add-on cgroup root
- **WHEN** a rollout from `0.3.1` to `0.3.2` evaluates candidate health
- **THEN** the rollout is not paused for that reason
- **AND** the fleet row for `anomaly` continues to show the reported reason

#### Scenario: A failed unit still blocks the rollout

- **GIVEN** `bumblebee` reports state `unhealthy` with reason `systemd unit failed` on an in-scope agent
- **WHEN** a rollout evaluates candidate health
- **THEN** the rollout pauses
- **AND** the recorded evidence names that agent and that reason

#### Scenario: An unreachable control interface still blocks the rollout

- **GIVEN** `netprobe` reports state `unhealthy` with reason `dial netprobe socket: connection refused`
- **WHEN** a rollout evaluates candidate health
- **THEN** the rollout pauses
- **AND** the recorded evidence names that agent and that reason

### Requirement: A blocked add-on rollout records the evidence that blocked it

When an add-on rollout pauses on health, it SHALL record the agent identifier,
the add-on-reported reason string, and the age of the evidence at the moment of
the decision. A rollout SHALL NOT pause on health without recording all three.

#### Scenario: Pause records actionable evidence

- **GIVEN** a rollout evaluates candidate health
- **AND** one in-scope agent reports a candidate fault
- **WHEN** the rollout pauses
- **THEN** the recorded block names that agent
- **AND** it includes the reason string the add-on reported
- **AND** it includes the evidence age used for the decision
