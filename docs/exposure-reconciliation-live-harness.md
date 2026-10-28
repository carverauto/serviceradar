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
