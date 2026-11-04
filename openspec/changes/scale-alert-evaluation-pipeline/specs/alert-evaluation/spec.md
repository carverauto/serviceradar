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

### Requirement: Candidates use a fixed key space and a dynamic stream map
Each match SHALL be published as a candidate on a subject derived from a fixed space of 1,024 virtual partitions, selected by a versioned hash of the rule id and group key, and grouped into fixed blocks of consecutive virtual partitions, so that a key's subject never changes.
CNPG SHALL hold a generation-numbered map that assigns every block to exactly one physical candidate stream, and that map SHALL be changeable at runtime without changing any key's subject.
Candidate streams SHALL use Limits retention, DiscardNew, no maximum age and a finite size from the JetStream profile. A candidate SHALL carry every field that any compiled rule or the alert builder reads, each value whole, together with a reference to the stored record. No per-candidate inbox row SHALL be written to CNPG.

#### Scenario: Matches for one group share a subject
- **GIVEN** a rule grouped by `device_uid`
- **WHEN** two synthetic events for `sr:synthetic-dev-000042` match it
- **THEN** both candidates SHALL be published to the same virtual partition subject

#### Scenario: Changing the stream count does not move a key's subject
- **GIVEN** a key routed to virtual partition 517 on an installation with one candidate stream
- **WHEN** the candidate stream count is raised to four
- **THEN** later candidates for that key SHALL still be published to virtual partition 517's subject

#### Scenario: A field no rule reads is not copied
- **GIVEN** a stored event with an attribute that no compiled rule or alert template references
- **WHEN** its candidate is built
- **THEN** the candidate SHALL omit that attribute
- **AND** the stored event SHALL still contain it
- **AND** every attribute the candidate does carry SHALL be identical to the stored value

### Requirement: Leased block ownership is fenced
Each block SHALL have at most one committing owner, chosen among core replicas with repository access, through a CNPG lease whose epoch increments on every acquisition and is compared against the database clock.
Every effect commit and checkpoint commit SHALL verify, in the same transaction, the owner's epoch for every block it touches, and a commit with a superseded epoch SHALL fail.
Blocks SHALL be rebalanced automatically across capable core replicas when replicas join or leave, through planned handoffs on the same fenced path.

#### Scenario: A stale owner cannot commit
- **GIVEN** replica A owns block 7 at epoch 12 and pauses past its lease expiry
- **AND** replica B acquires block 7 at epoch 13
- **WHEN** replica A resumes and attempts an effect commit touching block 7
- **THEN** the commit SHALL fail
- **AND** replica A SHALL stop processing block 7

#### Scenario: An unplanned failure is taken over
- **WHEN** the replica owning a block is terminated without a handoff
- **THEN** another core replica SHALL acquire the block after the lease expires
- **AND** it SHALL resume from the block's last committed checkpoint

#### Scenario: Adding a core node spreads the work
- **GIVEN** an installation with two core replicas sharing all blocks
- **WHEN** a third capable core replica joins
- **THEN** about a third of the blocks SHALL move to it through planned handoffs
- **AND** no setting change SHALL be required

### Requirement: Candidate streams reshard online without loss or reordering
The system SHALL split and merge candidate streams online by moving blocks between physical streams, and every move SHALL preserve per-key order, lose no candidate and fire no duplicate alert.
A move SHALL remove the block's subjects from the source stream before binding them to the target stream, so that no subject is bound to two streams. It SHALL record the source stream's last sequence after the removal as the cut sequence. The block's owner SHALL start consuming the block from the target stream only after its committed checkpoint for the block reaches the cut sequence.
Moves SHALL be journalled in CNPG and resumable after a coordinator failover, and publishes refused during a move SHALL be retried in place.

#### Scenario: A split under load keeps order
- **GIVEN** a single candidate stream receiving the target candidate rate
- **WHEN** the candidate stream count is raised from one to two
- **THEN** every candidate for each key SHALL be applied in publish order
- **AND** the set of fired alerts SHALL equal the oracle with no missing and no duplicate alert

#### Scenario: A publish refused at the cut is retried into the target
- **GIVEN** a candidate stored in the source stream whose PubAck was lost at the moment of the cut
- **WHEN** the router retries it and it is stored again in the target stream
- **THEN** the owner SHALL apply it once

#### Scenario: A coordinator failover mid-move
- **WHEN** the coordinator is terminated after the cut and before the rebind
- **THEN** the next coordinator SHALL resume the move from the journal with the recorded cut sequence
- **AND** the move SHALL complete

### Requirement: Capacity recommendations are surfaced in health
The coordinator SHALL compare each candidate and telemetry stream's sustained rate and fill, and each owner's lag and CPU, against stated per-stream and per-node bounds, and SHALL report a split, merge or add-capacity recommendation in health, naming the setting value to apply.
Stream moves SHALL run only when an operator changes the stream count setting, unless automatic resharding is enabled. With automatic resharding enabled, the coordinator SHALL apply its own recommendation only after a placement dry run succeeds and the trend has held for the hysteresis window.

#### Scenario: A busy stream recommends a split
- **WHEN** a candidate stream sustains more than its per-stream bound for the hysteresis window
- **THEN** health SHALL report a split recommendation naming the stream and the stream count to set
- **AND** no move SHALL start while automatic resharding is disabled

### Requirement: Small installations run with minimal overhead
With code defaults, an installation SHALL run one candidate stream and one owner process per core replica. An idle installation SHALL issue no alert-path CNPG statements other than lease renewals, and SHALL write no checkpoint that changes nothing.

#### Scenario: A quiet demo install
- **GIVEN** one core replica with default settings and no matching input for 30 minutes
- **WHEN** alert-path database activity is measured
- **THEN** it SHALL consist only of lease renewals

### Requirement: Evaluation state is deterministic and incrementally checkpointed
A block owner SHALL keep rule group state in memory and SHALL compute each decision only from that state, the candidate, and the immutable rule revision the candidate names, without reading a wall clock, a database or the outcome of an effect.
The owner SHALL periodically commit the changed groups, the persisted duplicate-suppression slices and each block's applied stream position in one fenced transaction, only after the effects of every candidate up to those positions have committed, and SHALL evict groups whose state equals the default.

#### Scenario: Replay reproduces state
- **GIVEN** a block checkpointed at sequence 1000
- **WHEN** a new owner replays the block's candidates after sequence 1000 up to sequence 1500
- **THEN** its group state after sequence 1500 SHALL equal the state the previous owner had after sequence 1500

#### Scenario: Quiet groups do not consume memory
- **WHEN** a group's window empties with no open incident and no running cooldown
- **THEN** the group SHALL be removed from memory and from the checkpoint store at the next checkpoint

### Requirement: Alert effects fire exactly once
Every alert effect SHALL carry a fire key derived only from the group state and the candidate, and SHALL be applied by insert-if-absent or by an update guarded by evaluation position, so that replaying any candidate creates no second incident, history row, notification job or published event.
A transient effect failure SHALL roll back the commit and recover the affected blocks from their checkpoints; a permanent effect failure SHALL be recorded with diagnostics and a health signal and SHALL NOT change the group state.

#### Scenario: A crash after the effect commit does not double-fire
- **GIVEN** a candidate that crosses a threshold and whose incident commit succeeded
- **WHEN** the owner crashes before its next checkpoint and the block is replayed
- **THEN** exactly one alert SHALL exist for that incident
- **AND** exactly one fire notification job SHALL exist for it

#### Scenario: Open incident metadata is not rewritten per record
- **GIVEN** an open incident receiving 5,000 matching synthetic events in one minute
- **WHEN** the owner processes them
- **THEN** the incident's occurrence count SHALL equal the number of occurrences
- **AND** the alert row SHALL be written at most once per effect commit

### Requirement: Duplicate candidates are counted once
A block owner SHALL suppress a candidate whose 128-bit candidate id it has applied for that block within the configured duplicate horizon, SHALL count each suppression, and SHALL persist the suppression state with the block's checkpoints, so that a new owner, or the same owner after a block move, suppresses the same duplicates.

#### Scenario: A redelivered source message republishes its candidates
- **GIVEN** a source message whose candidates were published and whose acknowledgement was lost
- **WHEN** the message is redelivered within the duplicate horizon and its candidates are published again
- **THEN** each occurrence SHALL be counted once in its group window
- **AND** the suppressed duplicates SHALL be counted

#### Scenario: Suppression survives failover
- **GIVEN** a duplicate that arrives after the block moved to a new owner, within the horizon
- **WHEN** the new owner applies it
- **THEN** it SHALL be suppressed

### Requirement: Evaluation backpressure is lag and never loss
Alert evaluation SHALL NOT lose a candidate or a signal's evaluation because of load, a slow owner, an unavailable store, a full stream or a stream move.
Owners SHALL read with ordered consumers that need no acknowledgement and have no delivery limit. Publishers SHALL retry refused publishes in place, without NAK and without an attempt limit, while signalling progress on the source message. A full stream SHALL refuse new publishes rather than evict accepted messages, and consumed messages SHALL be removed only behind committed checkpoints.

#### Scenario: A Falco burst becomes lag
- **GIVEN** a synthetic burst of 5,000 Falco events per minute that all match one rule
- **WHEN** evaluation falls behind
- **THEN** no source message SHALL reach a terminal delivery because of alert evaluation
- **AND** owner lag and lag age SHALL rise
- **AND** every occurrence SHALL eventually be evaluated in order

#### Scenario: A full candidate stream holds the router
- **GIVEN** a candidate stream at its size limit
- **WHEN** the router publishes a candidate
- **THEN** the publish SHALL be refused and retried in place
- **AND** no stored candidate SHALL be evicted
- **AND** the source message SHALL remain unacknowledged without being redelivered

### Requirement: Poison candidates are quarantined with an audited disposition
A candidate that makes the evaluator raise at the same sequence on three consecutive attempts SHALL be copied to the alert dead-letter stream with its error, recorded as a skipped sequence in the block's checkpoint, and reported as a critical health condition, after which the block SHALL continue.
Store or fence failures SHALL NOT be classified as poison.

#### Scenario: One malformed candidate does not stall a block
- **WHEN** a synthetic candidate crashes the evaluator on three consecutive attempts
- **THEN** it SHALL be stored in the alert dead-letter stream with its error
- **AND** the block SHALL continue with the next candidate
- **AND** health SHALL report the skipped sequence until it is redriven

### Requirement: External state reaches evaluation as ordered control input
Rule disable and delete, operator alert actions that an evaluation decision depends on, stale-anomaly maintenance, block moves and the cutover import end SHALL reach each affected block as messages on its subjects, published through the transactional outbox in the transaction that made the change.
Candidates of a disabled rule that follow its marker SHALL be dropped and counted, and an incident resolved by an operator SHALL NOT be renotified or re-fired until its group recovers.

#### Scenario: Disabling a rule is ordered with its candidates
- **GIVEN** candidates for rule R queued behind a disable marker for R
- **WHEN** the owner reaches them
- **THEN** they SHALL NOT be evaluated
- **AND** the dropped count SHALL include them

#### Scenario: An operator resolve is honoured on replay
- **GIVEN** an operator resolves an open incident and the block is later replayed across that point
- **WHEN** further matching candidates arrive before the group recovers
- **THEN** the incident SHALL NOT be renotified
- **AND** no new incident SHALL fire for that group

### Requirement: Stale-anomaly maintenance keeps its synchronous count
Stale-anomaly resolution SHALL publish a maintenance marker carrying its cutoff, time and live-series snapshot to every block, SHALL wait with a bounded timeout for one receipt per block, and SHALL return the summed count of resolved incidents.

#### Scenario: Maintenance follows earlier input
- **GIVEN** an anomaly-clear candidate published before a maintenance marker for the same group
- **WHEN** maintenance completes
- **THEN** the clear SHALL have been applied first
- **AND** the returned count SHALL not include that group

### Requirement: Alert evaluation health and telemetry
Alert evaluation SHALL publish lag, lag age, checkpoint age, applied rate, suppressed duplicates, dropped candidates and skipped poison per stream and per owner, together with router, stream fill and block move metrics, through JetStream with bounded labels that never include rule ids or block ids. Per-block detail SHALL be available on demand.
Health SHALL become degraded when lag age exceeds the degraded threshold or a block is unowned, and critical when lag age exceeds the critical threshold, stream fill exceeds its critical bound, a block move stalls, or poison or permanent effect failures exist, with one health event per transition.

#### Scenario: Lag is visible before any buffer is exhausted
- **WHEN** an owner's lag age exceeds 60 seconds
- **THEN** health SHALL report alert evaluation as degraded and name the owner and stream
- **AND** the candidate streams SHALL still have capacity

### Requirement: Alert evaluation settings live in CNPG
Every alert evaluation tuning value SHALL be a CNPG runtime setting whose code default is sized for a small installation. That includes the candidate stream count, owner placement, checkpoint interval and candidate cap, lease timing, batch shape, duplicate horizon, move concurrency, automatic resharding, publish retry caps and health thresholds.
No alert evaluation behaviour SHALL depend on a Helm-only value.

#### Scenario: Changing the checkpoint interval needs no redeploy
- **WHEN** an administrator changes the checkpoint interval setting
- **THEN** owners SHALL use the new interval without a Helm upgrade or a restart

#### Scenario: Raising the stream count needs no redeploy
- **WHEN** an administrator raises the candidate stream count setting
- **THEN** the coordinator SHALL move blocks online until the map matches it

### Requirement: Cutover from the CNPG inbox is ordered and complete
The upgrade SHALL start block owners only after no pre-cutover core replica remains, after existing rule state snapshots have been converted into block checkpoints, and after every residual inbox and pending lifecycle admission row has been published, in its original order, ahead of all later input for its block.
The old inbox, lane, receipt, ledger and pending-admission tables SHALL be dropped only after the cutover marker exists, and no runtime path SHALL evaluate through both designs.

#### Scenario: Residual work is evaluated before new input
- **GIVEN** an inbox holding accepted work for a rule when the upgrade begins
- **AND** new candidates for the same group routed by upgraded replicas during the roll
- **WHEN** the cutover completes
- **THEN** the residual work SHALL be evaluated before the new candidates
- **AND** no residual row SHALL remain unevaluated when the tables are dropped

### Requirement: Alert evaluation benchmark gates can fail
Router throughput, single-owner throughput, fault-injected exactly-once behaviour, semantic equivalence and the small-installation footprint SHALL be verified by tests on remote build execution for every change to the alert path. Fleet-scale synthetic load at 50,000 and 100,000 devices, and resharding under that load, SHALL be required in-cluster gates before every release cut.
Each gate SHALL fail on any discarded, terminally delivered or dead-lettered message, any alert missing from or duplicated against the generator's oracle, any per-key order violation, or any lag, latency, takeover, footprint or resource measurement over its threshold. Gate fixtures SHALL be synthetic.

#### Scenario: A duplicate alert fails the gate
- **WHEN** the fleet-scale run produces two alerts for one oracle incident
- **THEN** the gate SHALL fail and report the incident's fire key

#### Scenario: An order violation during a split fails the gate
- **WHEN** a key's candidates are applied out of publish order while its block moves between streams
- **THEN** the resharding gate SHALL fail and report the key and block

#### Scenario: A lag regression fails the gate
- **WHEN** sustained lag age p99 exceeds 30 seconds at the target rate
- **THEN** the gate SHALL fail
