# Hosted exposure interoperability check

The coordinator owns provisioning, exact-tree hosted execution, observer,
teardown, release and final schema-drop verification.

## Activation

Run the existing canonical hosted Core Integration owner with the existing
ExposureAssessmentTransitionsDbTest source and its NATS runfile. Select the
`live_warehouse` ExUnit tag (or the named test "live warehouse reconciliation
retains repairs through loss, upgrades and queued traffic") in that owner.
Forward these environment variables through the hosted runner into the test
action; never put their values in committed configuration:

- `EXPOSURE_LIVE_WAREHOUSE=1`
- `EXPOSURE_LIVE_DATABASE=exposure_reconcile_<32 lowercase hex characters>`
- `EXPOSURE_LIVE_FE_HTTP`: reachable FE HTTP origin, with BE redirects reachable
- `EXPOSURE_LIVE_MYSQL_HOST` and `EXPOSURE_LIVE_MYSQL_PORT`
- `EXPOSURE_LIVE_USER` and `EXPOSURE_LIVE_PASSWORD`

Use a never-used, uniquely owned scratch database and restricted identity for
every hosted execution, including retries; never reuse an earlier run's database
or the shared parity schema. StarRocks retains Stream Load labels across TRUNCATE,
and labels are unique within a database. Fresh CNPG runs can repeat source
sequences and deterministic load labels, so empty tables do not establish fresh
isolation. The coordinator must provision a new unique database for each run.
Provision the exposure tables using the actual
0032 through 0035 warehouse migrations with the scratch database qualifier.
The test does not create databases or run migrations. All five exposure tables
must initially be empty. Standard SERVICERADAR_STARROCKS_* startup variables
must remain unset/disabled: the test starts its own MySQL pool and temporarily
sets the production database qualifier only inside this serial test.

Without EXPOSURE_LIVE_WAREHOUSE the scenario is explicitly skipped, not a live
pass. Any supplied value other than 1 fails. Missing connection variables,
invalid schema names, an existing application MySQL pool, inaccessible or
nonempty tables fail before publication. The default mock tests do not read
these dedicated connection variables.

## Behavioral oracle

The scenario uses synthetic assessment helpers, real CNPG source functions,
the existing disposable JetStream broker, production snapshot workers and
processors, real Stream Load and the production MySQL query client. There are
no substituted warehouse queries, HTTP responses or production exports.
Dimension ingestion reads the selected outbox sequences from retained JetStream
messages and requires every selected sequence to be present. Core subscription
delivery counts are not used as evidence of retention: failed publishes can
reach subscribers, and deduplicated PubAcks need not produce another delivery.
The assigned CVE repair is verified immediately after ingestion and before
publishing newer queued content.

It asserts:

1. Snapshot publication/consumption completes, a fact exists in MySQL, and a
   subsequent comparison is required for scoped readiness.
2. Actual fact deletion leaves zero rows, blocks readiness, admits replacement
   publication and becomes ready after a newer snapshot and comparison.
3. Transactional owner-authorized trigger bypass changes current attributes
   while replay stays unchanged; reconciliation assigns a fresh sequence and
   retains a repair until real warehouse confirmation.
4. A missing V1 package produces a durable repair. Real relay PubAck is followed
   by deliberate consumer loss; upgrading to V2 removes V1 from current snapshot
   references. Reconciliation re-enqueues V1 and real dimension ingestion allows
   verification and eventual readiness.
5. A confirmed CVE repair can settle after new EPSS content is published while
   that newer outbox row remains queued.
6. An old comparison blocks scoped readiness. Disabled StarRocks returns
   starrocks_required while the CNPG assessment remains readable.

7. A real full snapshot and comparisons establish deployment readiness. A later
   scoped repair requires a comparison after its completion and restores global
   readiness without replacing the baseline. Another device's mismatch remains
   blocking; stale fleet enumeration also remains blocking.
8. Alternating CNPG-only and warehouse-only scopes fill a 500-item union page.
   A resumed job reaches the remaining fact-only u32 maximum ordinal, then
   terminates. Lifecycle-only warehouse scopes and exact job counts are checked.
9. Synthetic sequence-40 snapshot pages and sequence-41 live resolutions traverse
   retained JetStream messages and real Stream Load in both orders. MySQL must
   retain resolved sequence 41 before finalization, and accept sequence 42 after
   completion without reopening the generation.
10. Daily terminal compaction excludes recent resolutions and the exact cutoff,
    clears eligible resolved and retired payloads, and retains permanent markers.
    The durable cutoff advances to simulate age without waiting seven days.
    Repair verification accepts canonical compaction and rejects altered
    transaction markers or noncanonical payload. An older active delivery loses;
    a snapshot replays the same terminal publication without creating a repair.
    A delayed compaction load loses to a newer active transition.
11. A legacy repair obligation defers compaction of 1001 synthetic facts. After
    removing that test-owned obligation, the first 1000-row page succeeds. Invalid
    synthetic HTTP credentials cause the warehouse to return an actual HTTP 401
    for the next page. The successful-page cursor and original cutoff remain
    durable, and restoring the credentials lets retry clear the final row.

The separate controlled-response test covers filtered-load cursor recovery;
the live HTTP 401 case does not establish real warehouse filtered-row behavior.

The finite paging fixture is a functional boundary check, not fleet throughput
proof. Task 1.6 and the fleet reconciliation gate remain open. These assertions
require a fresh coordinator-owned hosted run; their presence is not pass evidence.

## Cleanup and result collection

The existing broker helper awaits nats-server exit. The publisher task is shut
down even on assertion failure. The supervised MySQL pool and load supervisor
are owned by ExUnit. Existing unboxed source cleanup removes assessment,
dictionary, outbox, reconciliation, generation, delivery-journal and job rows.
The global-readiness fixture restores pre-existing comparison metadata and
removes its newly created generations and jobs in the exclusive serial owner lane. The live
scenario truncates and re-queries all five initially empty, exclusively owned
warehouse tables, allowing up to five seconds for each zero-row result to
become visible, with a failing assertion at the deadline. The restricted test identity therefore needs TRUNCATE
permission on these scratch tables. Each table cleanup is attempted even if
another fails. Scenario and cleanup errors are collected separately and raised
together through ExUnit.MultiError, preserving their original stacktraces.
Pending finalizer repairs still fail the scenario. Before cleanup, that failure
reports up to five synthetic fact obligations, their current severity/KEV,
decoded retained publications, actual warehouse rows and up to twenty queued
transition sequences per fact. Connection configuration and raw query errors
are excluded; diagnostic failure does not replace the finalization failure.
The coordinator must still drop and verify absence of the scratch schema, including when preflight or cleanup fails.

## Compaction capacity (Decision 26)

The approved workload and measured results are owned by
[Decision 26](../openspec/changes/add-srql-exposure-intelligence/design.md#decision-26-define-the-maintenance-capacity-workload).

The explicit target `//elixir/serviceradar_core:exposure_compaction_capacity`
measures the production compactor with a real Oban Basic-engine queue. Run it
alone on a fresh `serial_2` clone through the same canonical hosted Core
Integration lifecycle (including its observer, teardown and generation release).
Select this target for both precompilation and test execution instead of the
ordinary lane suites. Do not run it beside or after the ordinary `serial_2`
suite: the Oban stager needs an otherwise idle scratch database. The target is
manual and is not part of ordinary PR CI.

Supply all `EXPOSURE_LIVE_*` variables above, plus
`EXPOSURE_CAPACITY_PROFILE=smoke` or `fleet`. Missing or other values fail.
Each run still needs a never-used, empty warehouse schema provisioned from the
actual migrations. The restricted identity additionally needs `INSERT` for
synthetic fixture construction. No source assessments or deployment exports are
copied. SQL generates the initial warehouse state outside the measured interval;
the test does not claim transition publication or ingestion throughput.

| Profile | Hosts | Active facts | Old terminal facts | Recent terminal controls |
| --- | --- | --- | --- | --- |
| smoke | 200 | 500,000 | 10,000 | 200 |
| fleet | 20,000 | 50,000,000 | 1,000,000 | 20,000 |

Both profiles cover 50,000 synthetic CVE ordinals. Each host has 2,500 active
facts, 50 old terminal facts split between resolved and retired, and one recent
resolved fact. The smoke profile exercises real scheduler resumption and the
whole result oracle; it is not fleet-scale proof.

The named test queue uses maintenance's concurrency of two, the real database
peer and the default stager. It does not call `perform/1` or drain jobs inline.
Elapsed time starts before enqueue and includes snoozes, queue scheduling and
the independent storage verification. Fixture preparation is reported separately.
At fifteen minutes an unfinished job fails and is cancelled before cleanup.

`EXPOSURE_COMPACTION_CAPACITY` reports the selected profile, setup and worker
durations, remaining rows and actual snooze count. A successful job is only an
intermediate result: `EXPOSURE_COMPACTION_CAPACITY_VERIFIED` requires exact row
counts and zero violations across every row. The oracle reconstructs expected
identities and publication markers from primary keys, requires unchanged active
and recent rows, and checks the complete canonical terminal payload. The final
elapsed time must still fit within fifteen minutes. An absent verification line,
failure, timeout or skipped execution is not a passing measurement.

Read the test verdict and canonical cleanup statuses, then remove and verify
absence of the external warehouse schema and its grants. A passed compaction
run does not close reconciliation, snapshot, arbitrary terminal-backlog or
concurrent-ingestion capacity gates.

Collect the actual named test result and canonical suite/observer/teardown/
release statuses. A compile/setup failure is not behavioral proof. Fresh hosted
execution of the source tree under review is required before claiming a pass.

## Daily reconciliation capacity

The manual target `//elixir/serviceradar_core:exposure_reconciliation_capacity`
measures the production fleet enumerator and per-device comparison workers. Run
it alone on a fresh canonical `serial_2` clone and a never-used warehouse schema,
with the same `EXPOSURE_LIVE_*` inputs and `EXPOSURE_CAPACITY_PROFILE` selector as
the compaction target. Keep the canonical observer, teardown and generation
release. The ordinary integration lane does not select this manual benchmark.

The warehouse identity must also support the negative control's `UPDATE` on
`exposure_facts`. The disposable CNPG clone's identity must be able to disable
and restore user triggers on the fixture tables and truncate them during cleanup.
The harness parks existing bootstrap jobs in an unserved queue and temporarily
stops `ObanFailureEventReporter`, because the exposure-only warehouse has no
generic event tables. It restores the bootstrap queues and original supervised
Oban and reporter processes after the run; persisted Oban errors remain the
failure oracle during measurement.

Smoke pairs 200 hosts and 500,000 active facts in CNPG and StarRocks. Fleet pairs
20,000 hosts and 50 million active facts. Both use all 50,000 synthetic CVEs,
2,551 shared package versions and 51 resolved controls per host. SQL constructs
this already-published starting state, including a completed recovery generation;
fixture preparation and initial full-table checks are excluded from elapsed time.
This does not measure source publication, snapshot rebuilding or mismatch repair
throughput.

The timed run uses the default Oban instance, Basic engine, database peer,
default stager and production `maintenance` concurrency of two. The fleet job
admits its own per-device jobs. It does not call `perform/1`, drain the queue or
change production queues during the measurement. Deadline or any job error is
an explicit failure. The result is not a pass until every scope has a fresh
matched comparison with 2,500 actionable rows, deployment readiness is true,
and a full warehouse oracle confirms all fact keys and actionable contents.

`EXPOSURE_RECONCILIATION_FIXTURE` reports setup time and assessment storage.
`EXPOSURE_RECONCILIATION_CAPACITY` is intermediate scheduling/comparison evidence.
Only `EXPOSURE_RECONCILIATION_CAPACITY_VERIFIED` establishes the timed result.
Afterward, changing one fact's severity while preserving the row count must
record a mismatch and block readiness; its separately reported negative control
runs outside the capacity timer. Both stores are cleared and checked before the
coordinator removes the disposable databases and verifies absence.

The first paired smoke run exposed a source-query bottleneck. The old scoped
dimension query correlated every catalogue entry with the device's assessments
and deletion watermarks. At only 200 hosts, it remained active just before the
30-second statement deadline, and reconciliation completed no device matches.
The replacement builds the distinct referenced keys once per page, then joins
the dimension catalogue. The full-scope snapshot path continues to page the
catalogue directly. The source view, returned keys, ordering and page size are
unchanged.

### Initial reconciliation measurements (2026-10-28)

The [baseline diagnostic run](https://carverauto.buildbuddy.io/invocation/3cebc714-0ff6-45fe-948e-a78f716443dd)
used source `f0be00f16a9478446fedb57a9d6746b29ecb4d43`, tree
`1eb44cb0ffeeebfd833dcfbc542c641d3da784f9`. It admitted the 200-device workload,
then failed after about 35 seconds with no matched devices. A read-only activity
trace found the scoped dimension query active at 29 seconds before its configured
30-second statement limit. The worker retained the failure as a rollback.

The [fixed smoke run](https://carverauto.buildbuddy.io/invocation/fb518418-5a56-45c0-adc8-8ceb4f629674)
used source `67fe02a045174b03a320ef656daa491ae064f7f1`, tree
`cee2e7f2b93ca2d8b8111b3b8ae418faf2c55470`. All 200 devices matched. Fixture
construction and initial verification took about 31 seconds, excluded from the
timer. Worker completion took about 244 seconds; including full verification,
the run took about 245 seconds. There were no remaining devices or content
violations, and the equal-count severity corruption was rejected. Assessment
storage including indexes was about 0.6 GiB. The canonical connection observer,
teardown and generation release passed, and the external scratch schemas and
grants were independently verified absent.

These are synthetic smoke measurements, not the 20,000-host/50-million-active-fact
fleet result or a p95 guarantee. The full fleet run has not been attempted: the
small-profile throughput remains far below the rate needed for the 15-minute
fleet budget. Task 1.6 remains open. The next capacity work must address that
per-device cost before loading the full source profile; this fix establishes
correct forward progress without claiming that the fleet gate is satisfied.

[Broad hosted BazelCI](https://carverauto.buildbuddy.io/invocation/57fcc5c5-314c-40b4-a238-c6299503c794)
passed all seven child invocations at the fixed source above. Required hosted
PR CI remains a separate final-head gate. No deployment or codec change is
included.
