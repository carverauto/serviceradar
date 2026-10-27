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
    A delayed compaction load loses to a newer active transition. A separate
    transport-failure case checks durable cursor recovery after a filtered load.

The finite paging fixture is a functional boundary check, not fleet throughput
proof. Task 1.6 and the <=15-minute fleet-scale gate remain open. These assertions
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

Collect the actual named test result and canonical suite/observer/teardown/
release statuses. A compile/setup failure is not behavioral proof. Fresh hosted
execution of the source tree under review is required before claiming a pass.
