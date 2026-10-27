# Hosted exposure interoperability check

Status: implemented, NOT EXECUTED. No new hosted lifecycle was dispatched in
this phase. The coordinator owns provisioning, exact-tree hosted execution,
observer, teardown, release and final schema-drop verification. Existing
ccc725 regression evidence does not validate this new scenario.

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

Use the coordinator's uniquely owned scratch schema and restricted identity,
never the shared parity schema. Provision the exposure tables using the actual
0032, 0033 and 0034 warehouse migrations with the scratch database qualifier.
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

The test does not establish full-fleet enumeration/paging, deployment-wide
coverage, both sequence40/41 delivery orders, or fleet throughput. Existing
head-bound evidence for those paths must be reported separately; task 1.6 and
the <=15-minute gate remain open.

## Cleanup and result collection

The existing broker helper awaits nats-server exit. The publisher task is shut
down even on assertion failure. The supervised MySQL pool and load supervisor
are owned by ExUnit. Existing unboxed source cleanup removes assessment,
dictionary, outbox, reconciliation, scoped generation and job rows. The live
scenario deletes and re-queries all five initially empty, exclusively owned
warehouse tables in an after block. The coordinator must still drop and verify
absence of the scratch schema, including when preflight or cleanup fails.

Collect the actual named test result and canonical suite/observer/teardown/
release statuses. A compile/setup failure is not behavioral proof. Fresh hosted
execution is required before claiming this gap closed. No tests, formatters,
linters or static analysis were run in this implementation phase: local
execution is forbidden and hosted lifecycle dispatch belongs to the outer
coordinator. The contract is in the worktree rather than /private/tmp to honor
the current workspace boundary.
