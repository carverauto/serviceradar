## ADDED Requirements

### Requirement: Falco events SHALL preserve runtime diagnostic context
The system SHALL normalize Falco runtime security detections into OCSF events that preserve operator-relevant diagnostic context from the Falco payload, including rule metadata, host, process identity, executable path, command line, working directory, parent process, user, executable flags, container identity, Kubernetes identity when present, and source log provenance.

#### Scenario: Falco dropped-binary event is promoted with process context
- **GIVEN** a Falco log for `Drop and execute new binary in container` includes `output_fields` for `proc.name`, `proc.cmdline`, `proc.cwd`, `proc.exe`, `proc.pname`, `evt.arg.flags`, `container.id`, and `hostname`
- **WHEN** the log is promoted into an OCSF event
- **THEN** the event SHALL expose normalized process, command, cwd, executable, parent, executable flags, container id, and host fields
- **AND** the event SHALL retain the source log id and original Falco payload for audit

#### Scenario: Falco event lacks Kubernetes enrichment
- **GIVEN** a Falco event includes a container id but does not include `k8s.pod.name` or `k8s.ns.name`
- **WHEN** the event is promoted
- **THEN** the event SHALL preserve the container id and host
- **AND** the event SHALL mark Kubernetes attribution as partial or missing instead of omitting the attribution state

### Requirement: Stateful security alerts SHALL include diagnostic summaries
The system SHALL include bounded diagnostic summaries on stateful security alerts generated from Falco-derived events so operators can understand why the alert fired without direct database or cluster access.

#### Scenario: Falco burst creates a diagnostic-rich alert
- **GIVEN** multiple Falco-derived events share the same stateful alert group within the configured window
- **WHEN** the stateful rule creates or updates an alert
- **THEN** the alert SHALL include rule id, rule name, grouping keys, threshold, window, cooldown, renotify values, occurrence count, first seen time, last seen time, and representative source event ids
- **AND** the alert SHALL include bounded top samples for process, command, cwd, executable flags, container id, host, and Kubernetes attribution when available

#### Scenario: Alert summary is bounded during high-volume bursts
- **GIVEN** a Falco-derived event burst contains hundreds of source events in one stateful window
- **WHEN** the alert diagnostic summary is stored
- **THEN** the summary SHALL store aggregate counts and bounded representative samples
- **AND** it SHALL NOT copy every source event payload into the alert metadata

#### Scenario: Operator can follow alert provenance
- **GIVEN** a stateful security alert was generated from promoted Falco events
- **WHEN** an operator or API client inspects the alert
- **THEN** the alert SHALL expose the source log name, source log provider, source event ids, and source event time range used for the alert decision
- **AND** the operator SHALL be able to distinguish the stateful alert event from the raw Falco source events
