## ADDED Requirements

### Requirement: Superseded add-on rollouts terminate instead of lingering

A PAUSED add-on rollout SHALL resolve as superseded when every in-scope target
already reports the candidate version as its observed version, regardless of how
the targets reached it. Superseded rollouts SHALL be terminal: they are not
paused, not resumable, and not counted as outstanding work.

Supersession SHALL apply only to a rollout that cannot make progress on its own.
A rollout that is still advancing and whose targets report the candidate version
has SUCCEEDED, and SHALL complete through the normal promotion path; observed
version alone cannot distinguish that case from convergence by another route, so
the paused precondition is what separates them.

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

#### Scenario: An advancing rollout that reaches the candidate completes, not superseded

- **GIVEN** a rollout is running and its targets report the candidate version healthy
- **WHEN** rollout state is next evaluated
- **THEN** the rollout completes through the normal promotion path
- **AND** it is NOT resolved as superseded

#### Scenario: Partially converged rollout is left alone

- **GIVEN** a rollout of `scalibr-endpoint-inventory` from `0.1.1` to `0.1.3`
- **AND** in-scope agents report observed version `0.1.2`
- **WHEN** rollout state is next evaluated
- **THEN** the rollout is NOT resolved as superseded
- **AND** its existing state and blocked reason are preserved

### Requirement: A degradation note alone does not fail a rollout candidate

Rollout health gating SHALL treat the add-on's reported STATE as the decision
input. A degradation reason accompanying a running add-on is advisory: it
describes something worth an operator's attention, not a failed candidate, and
SHALL NOT by itself pause a rollout.

Today any non-empty `degradation_reason` is treated as an explicit candidate
failure regardless of state, which is why an add-on that is running normally but
reports an unenforceable host resource policy can hold its rollout indefinitely.

An advisory degradation SHALL remain visible on the fleet row, so that no longer
gating on it never means no longer reporting it. It SHALL be surfaced from the
reported status rather than copied onto the rollout: the status row is already
the authoritative record, and duplicating it onto the rollout would create a
second copy that can drift from the agent's current report.

#### Scenario: Running add-on with a host-policy note does not block the rollout

- **GIVEN** `anomaly` reports state `running` on every in-scope agent
- **AND** each agent reports `resource limits not enforced` for the add-on cgroup root
- **WHEN** a rollout from `0.3.1` to `0.3.2` evaluates candidate health
- **THEN** the rollout is not paused for that reason
- **AND** the fleet row for `anomaly` continues to show the reported reason

#### Scenario: A reported failure state still blocks the rollout

- **GIVEN** `bumblebee` reports state `unhealthy` with reason `systemd unit failed` on an in-scope agent
- **WHEN** a rollout evaluates candidate health
- **THEN** the rollout pauses
- **AND** the recorded evidence names that agent and that reason

#### Scenario: An unreachable control interface still blocks the rollout

- **GIVEN** `netprobe` reports state `unhealthy` with reason `dial netprobe socket: connection refused`
- **WHEN** a rollout evaluates candidate health
- **THEN** the rollout pauses
- **AND** the recorded evidence names that agent and that reason

### Requirement: Add-ons distinguish not-ready from unhealthy

An add-on SHALL report `unhealthy` only when the add-on itself is failing. An
add-on that is running correctly but has no upstream input, no work to do, or an
unsatisfied external dependency SHALL report that it is running and not ready,
not that it is unhealthy.

This is a liveness-versus-readiness distinction. Rollout gating acts on liveness,
because that is the only signal that says anything about the candidate build.
Readiness is a property of the deployment around the add-on and is identical
before and after an upgrade, so gating on it can only ever wedge the rollout.

#### Scenario: PowerDNS add-on with no upstream producer

- **GIVEN** the `powerdns` add-on is running correctly
- **AND** no PowerDNS Recursor is connected to its protobuf listener
- **WHEN** it reports status
- **THEN** it reports a running state with a not-ready indication
- **AND** it does not report state `unhealthy`
- **AND** a rollout of that add-on is not paused for that reason

#### Scenario: PowerDNS add-on that is actually failing

- **GIVEN** the `powerdns` add-on cannot bind its protobuf listener
- **WHEN** it reports status
- **THEN** it reports state `unhealthy`
- **AND** a rollout of that add-on pauses with that reason recorded

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
