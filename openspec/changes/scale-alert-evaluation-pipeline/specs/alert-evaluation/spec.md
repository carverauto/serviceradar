## ADDED Requirements

### Requirement: Compiled rule index routes stored records
EventWriter SHALL match every stored log, event and metric record against a compiled index of the active stateful and promotion rules, so that the matching cost grows with the number of candidate rules and not with the total number of rules.
The index SHALL be rebuilt when a rule changes rather than on a timer, and a record that matches no rule SHALL produce no candidate and no database work.
The final match decision SHALL use the same predicate semantics as the current rule matcher, including the anomaly-open subject guard.

#### Scenario: Unmatched record costs no evaluation work
- **GIVEN** 500 active stateful rules, none of which matches a synthetic log record from `host000001.example.com`
- **WHEN** EventWriter stores the record
- **THEN** no candidate SHALL be published for it
- **AND** no alert-evaluation row SHALL be written to CNPG for it

#### Scenario: A rule edit takes effect without a timer
- **GIVEN** a rule whose `subject_prefix` is changed by an operator
- **WHEN** the change commits
- **THEN** every EventWriter replica SHALL rebuild its index from the new rule-set version
- **AND** records routed afterwards SHALL be matched against the new revision

### Requirement: Partitioned candidate streams carry evaluation input
Each match SHALL be published as a candidate on a JetStream subject selected by a versioned hash of the rule id and group key over a fixed number of logical partitions, and the logical partitions SHALL map onto physical streams through a complete, non-overlapping map stored in CNPG.
Candidate streams SHALL use Limits retention, DiscardNew, no maximum age and a finite size from the JetStream profile, and a candidate SHALL carry every field that any compiled rule or the alert builder reads, each value whole, together with a reference to the stored record.
No per-candidate inbox row SHALL be written to CNPG.

#### Scenario: Matches for one group land on one partition
- **GIVEN** a rule grouped by `device_uid`
- **WHEN** two synthetic events for `sr:synthetic-dev-000042` match it
- **THEN** both candidates SHALL be published to the same logical partition subject

#### Scenario: A field no rule reads is not copied
- **GIVEN** a stored event with an attribute that no compiled rule or alert template references
- **WHEN** its candidate is built
- **THEN** the candidate SHALL omit that attribute
- **AND** the stored event SHALL still contain it
- **AND** every attribute the candidate does carry SHALL be identical to the stored value

### Requirement: Leased partition ownership is fenced
Each logical partition SHALL have at most one committing owner, chosen among core replicas with repository access, through a CNPG lease whose epoch increments on every acquisition and is compared against the database clock.
Every effect commit and checkpoint commit for a partition SHALL verify the owner's lease epoch in the same transaction, and a commit with a superseded epoch SHALL fail.

#### Scenario: A stale owner cannot commit
- **GIVEN** replica A owns partition 7 at epoch 12 and pauses past its lease expiry
- **AND** replica B acquires partition 7 at epoch 13
- **WHEN** replica A resumes and attempts an effect commit
- **THEN** the commit SHALL fail
- **AND** replica A SHALL stop processing partition 7

#### Scenario: An unplanned failure is taken over
- **WHEN** the replica owning a partition is terminated without a handoff
- **THEN** another core replica SHALL acquire the partition after the lease expires
- **AND** it SHALL resume from the last committed checkpoint

### Requirement: Evaluation state is deterministic and incrementally checkpointed
A partition owner SHALL keep rule group state in memory and SHALL compute each decision only from that state, the candidate, and the immutable rule revision the candidate names, without reading a wall clock, a database or the outcome of an effect.
The owner SHALL periodically commit the changed groups, the persisted duplicate-suppression slices and the applied stream sequence in one fenced transaction, only after the effects of every candidate up to that sequence have committed, and SHALL evict groups whose state equals the default.

#### Scenario: Replay reproduces state
- **GIVEN** a partition checkpointed at sequence 1000
- **WHEN** a new owner replays candidates 1001 to 1500 from that checkpoint
- **THEN** its group state after candidate 1500 SHALL equal the state the previous owner had after candidate 1500

#### Scenario: Quiet groups do not consume memory
- **WHEN** a group's window empties with no open incident and no running cooldown
- **THEN** the group SHALL be removed from memory and from the checkpoint store at the next checkpoint

### Requirement: Alert effects fire exactly once
Every alert effect SHALL carry a fire key derived only from the group state and the candidate, and SHALL be applied by insert-if-absent or by an update guarded by evaluation sequence, so that replaying any candidate creates no second incident, history row, notification job or published event.
A transient effect failure SHALL roll back the commit and recover the partition from its checkpoint; a permanent effect failure SHALL be recorded with diagnostics and a health signal and SHALL NOT change the group state.

#### Scenario: A crash after the effect commit does not double-fire
- **GIVEN** a candidate that crosses a threshold and whose incident commit succeeded
- **WHEN** the owner crashes before its next checkpoint and the partition is replayed
- **THEN** exactly one alert SHALL exist for that incident
- **AND** exactly one fire notification job SHALL exist for it

#### Scenario: Open incident metadata is not rewritten per record
- **GIVEN** an open incident receiving 5,000 matching synthetic events in one minute
- **WHEN** the owner processes them
- **THEN** the incident's occurrence count SHALL equal the number of occurrences
- **AND** the alert row SHALL be written at most once per effect commit

### Requirement: Duplicate candidates are counted once
A partition owner SHALL suppress a candidate whose 128-bit candidate id it has applied within the configured duplicate horizon, SHALL count each suppression, and SHALL persist the suppression state with its checkpoints so that a new owner suppresses the same duplicates.

#### Scenario: A redelivered source message republishes its candidates
- **GIVEN** a source message whose candidates were published and whose acknowledgement was lost
- **WHEN** the message is redelivered within the duplicate horizon and its candidates are published again
- **THEN** each occurrence SHALL be counted once in its group window
- **AND** the suppressed duplicates SHALL be counted

#### Scenario: Suppression survives failover
- **GIVEN** a duplicate that arrives after the partition moved to a new owner, within the horizon
- **WHEN** the new owner applies it
- **THEN** it SHALL be suppressed

### Requirement: Evaluation backpressure is lag and never loss
Alert evaluation SHALL NOT lose a candidate or a signal's evaluation because of load, a slow owner, an unavailable store or a full stream.
Owners SHALL read with ordered consumers that need no acknowledgement and have no delivery limit. Publishers SHALL retry refused publishes in place, without NAK and without an attempt limit, while signalling progress on the source message. A full stream SHALL refuse new publishes rather than evict accepted messages, and consumed messages SHALL be removed only behind a committed checkpoint.

#### Scenario: A Falco burst becomes lag
- **GIVEN** a synthetic burst of 5,000 Falco events per minute that all match one rule
- **WHEN** evaluation falls behind
- **THEN** no source message SHALL reach a terminal delivery because of alert evaluation
- **AND** partition lag and lag age SHALL rise
- **AND** every occurrence SHALL eventually be evaluated in order

#### Scenario: A full candidate stream holds the router
- **GIVEN** a candidate stream at its size limit
- **WHEN** the router publishes a candidate
- **THEN** the publish SHALL be refused and retried in place
- **AND** no stored candidate SHALL be evicted
- **AND** the source message SHALL remain unacknowledged without being redelivered

### Requirement: Poison candidates are quarantined with an audited disposition
A candidate that makes the evaluator raise at the same sequence on three consecutive attempts SHALL be copied to the alert dead-letter stream with its error, recorded as a skipped sequence in the partition checkpoint, and reported as a critical health condition, after which the partition SHALL continue.
Store or fence failures SHALL NOT be classified as poison.

#### Scenario: One malformed candidate does not stall a partition
- **WHEN** a synthetic candidate crashes the evaluator on three consecutive attempts
- **THEN** it SHALL be stored in the alert dead-letter stream with its error
- **AND** the partition SHALL continue with the next candidate
- **AND** health SHALL report the skipped sequence until it is redriven

### Requirement: External state reaches evaluation as ordered control input
Rule disable and delete, operator alert actions that an evaluation decision depends on, stale-anomaly maintenance, and the cutover import end SHALL reach each affected partition as messages on its subject, published through the transactional outbox in the transaction that made the change.
Candidates of a disabled rule that follow its marker SHALL be dropped and counted, and an incident resolved by an operator SHALL NOT be renotified or re-fired until its group recovers.

#### Scenario: Disabling a rule is ordered with its candidates
- **GIVEN** candidates for rule R queued behind a disable marker for R
- **WHEN** the owner reaches them
- **THEN** they SHALL NOT be evaluated
- **AND** the dropped count SHALL include them

#### Scenario: An operator resolve is honoured on replay
- **GIVEN** an operator resolves an open incident and the partition is later replayed across that point
- **WHEN** further matching candidates arrive before the group recovers
- **THEN** the incident SHALL NOT be renotified
- **AND** no new incident SHALL fire for that group

### Requirement: Stale-anomaly maintenance keeps its synchronous count
Stale-anomaly resolution SHALL publish a maintenance marker carrying its cutoff, time and live-series snapshot to every partition, SHALL wait with a bounded timeout for one receipt per partition, and SHALL return the summed count of resolved incidents.

#### Scenario: Maintenance follows earlier input
- **GIVEN** an anomaly-clear candidate published before a maintenance marker for the same group
- **WHEN** maintenance completes
- **THEN** the clear SHALL have been applied first
- **AND** the returned count SHALL not include that group

### Requirement: Alert evaluation health and telemetry
Alert evaluation SHALL publish per-partition lag, lag age, checkpoint age, owner, epoch, applied rate, suppressed duplicates, dropped candidates and skipped poison, together with router and stream fill metrics, through JetStream with bounded labels that never include rule ids.
Health SHALL become degraded when lag age exceeds the degraded threshold or a partition is unowned, and critical when lag age exceeds the critical threshold, stream fill exceeds its critical bound, or poison or permanent effect failures exist, with one health event per transition.

#### Scenario: Lag is visible before any buffer is exhausted
- **WHEN** a partition's lag age exceeds 60 seconds
- **THEN** health SHALL report alert evaluation as degraded and name the partition
- **AND** the candidate streams SHALL still have capacity

### Requirement: Alert evaluation settings live in CNPG
Every alert evaluation tuning value SHALL be a CNPG runtime setting with a code default, including checkpoint interval and candidate cap, lease timing, batch shape, duplicate horizon, handoff concurrency, publish retry caps and health thresholds.
Partition count and the physical stream map SHALL be install-time CNPG rows, and no alert evaluation behaviour SHALL depend on a Helm-only value.

#### Scenario: Changing the checkpoint interval needs no redeploy
- **WHEN** an administrator changes the checkpoint interval setting
- **THEN** partition owners SHALL use the new interval without a Helm upgrade or a restart

### Requirement: Cutover from the CNPG inbox is ordered and complete
The upgrade SHALL start partition owners only after no pre-cutover core replica remains, after existing rule state snapshots have been converted into partition checkpoints, and after every residual inbox and pending lifecycle admission row has been published, in its original order, ahead of all later input for its partition.
The old inbox, lane, receipt, ledger and pending-admission tables SHALL be dropped only after the cutover marker exists, and no runtime path SHALL evaluate through both designs.

#### Scenario: Residual work is evaluated before new input
- **GIVEN** an inbox holding accepted work for a rule when the upgrade begins
- **AND** new candidates for the same group routed by upgraded replicas during the roll
- **WHEN** the cutover completes
- **THEN** the residual work SHALL be evaluated before the new candidates
- **AND** no residual row SHALL remain unevaluated when the tables are dropped

### Requirement: Alert evaluation benchmark gates can fail
Router throughput, single-partition throughput, fault-injected exactly-once behaviour and semantic equivalence SHALL be verified by tests on remote build execution for every change to the alert path, and a fleet-scale synthetic load gate SHALL be required before every release cut.
The fleet-scale gate SHALL fail on any discarded, terminally delivered or dead-lettered message, any alert missing from or duplicated against the generator's oracle, or any lag, latency, takeover or resource measurement over its threshold, and its fixtures SHALL be synthetic.

#### Scenario: A duplicate alert fails the gate
- **WHEN** the fleet-scale run produces two alerts for one oracle incident
- **THEN** the gate SHALL fail and report the incident's fire key

#### Scenario: A lag regression fails the gate
- **WHEN** sustained lag age p99 exceeds 30 seconds at the target rate
- **THEN** the gate SHALL fail
