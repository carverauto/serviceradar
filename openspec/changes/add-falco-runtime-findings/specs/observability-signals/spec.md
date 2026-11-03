## ADDED Requirements

### Requirement: Runtime finding transitions drive Falco alerting
The system SHALL emit a runtime finding lifecycle transition (`opened`, `reopened`, `escalated`, `resolved`) through a transactional outbox committed with the finding change, and SHALL relay each transition as an OCSF Detection Finding event in `ocsf_events` and admit it to `StatefulAlertEngine`.
Each transition SHALL carry the next per-finding `transition_seq`, a deterministic event id derived from the finding uid and that sequence, the finding's episode severity as `severity_id`, and the finding's bound device uid. Opened, reopened, and escalated transitions SHALL use `log_name` `falco.finding.firing.<transition>`. A resolved transition SHALL use `log_name` `falco.finding.resolved`. The attribute map the alert matcher reads SHALL carry `finding_info.uid`, `runtime_finding.transition`, `runtime_finding.rule`, and `runtime_finding.entity_name`, and those fields SHALL also be on `metadata` with a bounded runtime finding summary (entity, binding, counts, samples, latest occurrence ids).

#### Scenario: Crash after commit does not lose the opening transition
- **GIVEN** a batch creates a new finding and the process stops after the CNPG commit and before the relay runs
- **WHEN** the relay resumes
- **THEN** the `opened` transition SHALL be relayed and admitted exactly once

#### Scenario: Replayed relay is idempotent
- **GIVEN** a transition that was relayed and admitted
- **WHEN** the relay replays it
- **THEN** no second event row and no second alert evaluation input SHALL result

### Requirement: Falco occurrences are not alert inputs
The Falco ingestion paths SHALL NOT admit individual Falco occurrences to `StatefulAlertEngine`; only runtime finding transitions SHALL be admitted.
Falco alerting SHALL be lifecycle only: no managed rule SHALL alert on occurrence volume, rate, or window counts.

#### Scenario: Burst admits one transition
- **GIVEN** 10,000 critical occurrences of one rule from one workload arrive within a minute and no finding exists for it
- **WHEN** they are processed
- **THEN** the alert engine SHALL receive one `opened` transition for that finding
- **AND** it SHALL receive no per-occurrence input

### Requirement: Managed runtime finding alert rule
The rule seeder SHALL provide a managed stateful alert rule `falco_runtime_finding` whose firing match is `subject_prefix` `falco.finding.firing.`, `attribute_equals` on `runtime_finding.transition` for `opened`, `reopened`, or `escalated`, and `severity_number_min` 5. It SHALL group by `finding_info.uid`, fire at threshold 1 with a 300 second cooldown and a 21,600 second renotify interval, and recover on `subject_prefix` `falco.finding.resolved` with `runtime_finding.transition` equal to `resolved`. The firing `subject_prefix` SHALL NOT be a prefix of the recovery subject. A resolved transition SHALL NOT take the firing path.
The rule's title SHALL name the rule and the subject entity through the placeholders `runtime_finding.rule` and `runtime_finding.entity_name`, and descriptive values MUST NOT appear in `group_by`. The admitted event SHALL carry `finding_info.uid`, `runtime_finding.rule`, and `runtime_finding.entity_name` where `group_by` and the title template resolve them.

#### Scenario: One alert per finding
- **GIVEN** critical findings for the same rule on three different workloads open within one minute
- **WHEN** the transitions are evaluated
- **THEN** three alerts SHALL be created, one per finding

#### Scenario: Resolution recovers the alert
- **GIVEN** an active alert for a Critical finding
- **WHEN** the finding auto-resolves and its `resolved` transition is evaluated
- **THEN** the firing predicate SHALL NOT match that transition
- **AND** the alert SHALL be resolved

### Requirement: Retired managed stateful rule templates
The rule seeder SHALL keep a list of retired stateful rule templates with their last shipped version, SHALL NOT create retired rules, and on boot SHALL disable and mark retired a retired rule that is managed and whose fingerprint equals the last shipped template.
Active alerts of a rule retired this way SHALL be resolved with reason `superseded_by_runtime_findings`. An operator-modified managed copy or an unmanaged rule with a retired name SHALL NOT be rewritten onto the runtime-finding subjects. Once the `falco.*` NATS subjects are removed, that copy SHALL receive no events and SHALL go silent. `falco_critical_incident` template version 1 SHALL be the first retired template.

#### Scenario: Pristine legacy rule is retired
- **GIVEN** a managed `falco_critical_incident` rule at template version 1 with an unmodified fingerprint and one active alert
- **WHEN** the seeder runs after upgrade
- **THEN** the rule SHALL be disabled and marked retired
- **AND** its active alert SHALL be resolved with reason `superseded_by_runtime_findings`

#### Scenario: Customized legacy rule goes silent
- **GIVEN** an operator changed the `group_by` of `falco_critical_incident`
- **WHEN** the seeder runs after upgrade and the `falco.*` subjects are removed
- **THEN** the seeder SHALL NOT rewrite the rule to match runtime finding transitions
- **AND** the rule SHALL receive no events

## MODIFIED Requirements

### Requirement: Event-derived alerts SHALL be incident-grouped
The system SHALL treat repeated event-derived alerts as incident updates when incoming events resolve to the same incident fingerprint and the existing incident is still active.

#### Scenario: Repeated Falco critical detections collapse into one incident
- **GIVEN** critical Falco-promoted events that share the same configured incident grouping fields
- **WHEN** multiple matching events arrive while the incident is still active
- **THEN** the system SHALL keep a single active alert incident for that fingerprint
- **AND** duplicate events SHALL update the active incident instead of creating new alert rows

#### Scenario: Repeated runtime finding transitions update one incident
- **GIVEN** an active alert for a runtime finding
- **WHEN** an `escalated` transition for the same finding arrives inside the cooldown window
- **THEN** the system SHALL update the existing incident instead of creating a new alert row

#### Scenario: A new incident is created after the previous incident is no longer active
- **GIVEN** an earlier event-derived incident has been resolved or aged out of its suppression window
- **WHEN** a matching event arrives again
- **THEN** the system SHALL create a new alert incident
- **AND** the new incident SHALL remain linked to the triggering event
