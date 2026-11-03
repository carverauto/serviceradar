## ADDED Requirements

### Requirement: Falco events SHALL preserve runtime diagnostic context
The system SHALL preserve operator-relevant diagnostic context from each Falco payload on the runtime security occurrence, including rule metadata, host, process identity, executable path, command line, working directory, parent process, user, executable flags, container identity, Kubernetes identity when present, and source provenance, and SHALL NOT promote each Falco log into an OCSF event that keeps the raw payload.
Occurrence storage, including the raw record in `runtime_security_occurrences`, is owned by `add-falco-runtime-findings`. An `ocsf_events` row for Falco is written only for a lifecycle transition on `runtime_security.finding.*`.

#### Scenario: Falco dropped-binary occurrence keeps process context
- **GIVEN** a Falco record for `Drop and execute new binary in container` includes `output_fields` for `proc.name`, `proc.cmdline`, `proc.cwd`, `proc.exe`, `proc.pname`, `evt.arg.flags`, `container.id`, and `hostname`
- **WHEN** the occurrence is stored
- **THEN** the occurrence SHALL expose normalized process, command, cwd, executable, parent, executable flags, container id, and host fields
- **AND** the raw record SHALL remain on that occurrence, as specified by `add-falco-runtime-findings`

#### Scenario: Falco event lacks Kubernetes enrichment
- **GIVEN** a Falco event includes a container id but does not include `k8s.pod.name` or `k8s.ns.name`
- **WHEN** the occurrence is stored
- **THEN** the occurrence SHALL preserve the container id and host
- **AND** the occurrence SHALL mark Kubernetes attribution as partial or missing instead of omitting the attribution state

### Requirement: Stateful security alerts SHALL include diagnostic summaries
The system SHALL include bounded diagnostic summaries on stateful security alerts generated from Falco runtime-finding lifecycle transitions on `runtime_security.finding.*` so operators can understand why the alert fired without direct database or cluster access.
`add-falco-runtime-findings` owns lifecycle-only alerting. These summaries ride that transition. This requirement does not alert on occurrence volume.

#### Scenario: Falco lifecycle alert carries a diagnostic summary
- **GIVEN** a runtime finding lifecycle transition on `runtime_security.finding.firing.opened` carries the finding's diagnostic summary
- **WHEN** the stateful rule creates or updates an alert
- **THEN** the alert SHALL include rule id, rule name, grouping keys, threshold, window, cooldown, renotify values, occurrence count, first seen time, last seen time, and representative source occurrence ids
- **AND** the alert SHALL include bounded top samples for process, command, cwd, executable flags, container id, host, and Kubernetes attribution when available

#### Scenario: Alert summary is bounded during high-volume bursts
- **GIVEN** a Falco occurrence burst contains hundreds of occurrences for one finding
- **WHEN** the alert diagnostic summary is stored
- **THEN** the summary SHALL store aggregate counts and bounded representative samples
- **AND** it SHALL NOT copy every source occurrence payload into the alert metadata

#### Scenario: Operator can follow alert provenance
- **GIVEN** a stateful security alert was generated from a runtime finding lifecycle transition
- **WHEN** an operator or API client inspects the alert
- **THEN** the alert SHALL expose the lifecycle log name, log provider, source occurrence ids, and source time range used for the alert decision
- **AND** the operator SHALL be able to distinguish the stateful alert from the raw Falco occurrences in `runtime_security_occurrences`
