---
title: CI Schema Templates
---

# CI schema templates

The keyed schema-template lifecycle is the configured source for BazelCI,
LargeIngestionGate, and the integration benchmark actions. The legacy singleton
remains protected for rollback, but active callers neither migrate it nor clone it.
A successful manifest artifact test proves the build contract, not database
construction or isolation; the in-cluster evidence below remains mandatory.

## Execution boundary

Run these database operations only inside the guarded BuildBuddy cluster workflow
using the typed `ci` fixture configuration. They require
`--//build:enable_integration_tests`; the flag grants target compatibility, not
permission to run against an arbitrary database. Use the existing fixture credential
setup and verified TLS. Do not substitute a localhost endpoint, an ad hoc DSN,
production credentials, or schema-affecting environment overrides.

`--config=ci` uses the cluster executor's cache layout. The commands below are
in-cluster qualification examples, not workstation commands. The Python manifest
unit/artifact tests can run separately with `--config=remote` without a database.

Keep one checkout, manifest, and run ID across preparation, migration, cloning,
suite execution, teardown, and lease release. Run IDs must be 8-32 lowercase
ASCII letters or digits, unique per run. `example01` below is invented; replace it
with a fresh run ID. If measured execution uses a different ID from preflight, it
must acquire its own lease with `prepare_generation`, confirm the same full digest,
and require `ready` before entering the timed section. A lease is tied to the
derived run database name, not to a branch.

## Manifest and construction

`//build/schema_template:manifest` supplies the declared
`build/schema_template/manifest.json` artifact to consumers through runfiles. Never
read it by resolving a path inside `bazel-out`. Its identity covers sorted input
paths and file hashes, including migrations, baseline SQL and metadata, helper
code, construction code/configuration, dependency locks, registry SQL, and policy.
The full SHA-256 digest selects a database named `sr_tpl_` plus its first 48 hex
characters. Registry checks compare the full identity, so a truncated-name
collision cannot authorize reuse.

The policy intentionally selects `full_replay`: cold generation construction
executes every migration. Existing baseline metadata has an SQL checksum and
`included_through`, but no historical migration content provenance. Checking that
checksum does not prove that an edited historical migration is represented by the
baseline. `covered_migrations.digest` records current covered source contents for
future comparisons; it supplies no missing historical evidence. Baseline files
are still hashed and invalidate identity when changed.

Full replay does not replace cold baseline qualification. The production bootstrap
path must still pass its separate cold-baseline checks, including diagnosis of the
reported shared-lock exhaustion. Do not interpret replay success as resolving that
failure or silently change bootstrap strategy to get a green gate.

The separate production bootstrap baseline applies the same extension privilege
discipline as the migrations: operator-owned extension comments are omitted, the
optional statistics extension keeps its insufficient-privilege guard, and required
extension creation still fails loudly. That does not make a schema-only dump a valid
keyed-generation constructor; Timescale and AGE catalog state still requires full
migration replay.

## Keyed lifecycle

Invoke each step separately and stop on a nonzero exit or unexpected output.
These examples assume `SERVICERADAR_ENV=ci` is already selected by the guarded
workflow and fixture credentials have been materialized through its existing setup.

1. Prepare or reuse the generation, outside benchmark timing:

   ```text
   bazel run -c opt --config=ci --//build:enable_integration_tests --//build:run_id=example01 //rust/integration-db:prepare_generation
   ```

   Parse the program's JSON output, separately from Bazel diagnostics. Successful
   output contains `status`, `digest`, `database`, and integer `builder_token`.
   `status` is exactly `ready` or `needs_migration`. Validate the returned identity
   against the declared manifest; do not grep migration-count text. Missing or
   unknown status is a failure.

   `ready` means reuse passed registry identity, fixture compatibility, and catalog
   checks, and the run lease was renewed. Skip the BEAM migrator.
   `needs_migration` means a private database is registered as `building` and has
   extensions installed. It is not cloneable. Registry initialization is performed
   by preparation; do not apply registry DDL manually.

2. Only for `needs_migration`, run the guarded migrator:

   ```text
   bazel test -c opt --config=ci --strategy=TestRunner=local --//build:enable_integration_tests --//build:run_id=example01 --test_env=SERVICERADAR_ENV=ci --flaky_test_attempts=1 //elixir/serviceradar_core:migrate_generation
   ```

   The migrator holds the generation session lock in the administrative `postgres`
   database, acquires a fresh fencing token, requires an empty migration ledger,
   replays all migrations, and verifies the complete expected ledger and extension
   versions. It stops the Repo, disables connections to the candidate, checks the
   storage budget, and publishes `ready` using the ownership fence. Its interface
   is an ExUnit result, not the Rust preparation JSON protocol. Repeat step 1 after
   success and require `ready` with the same digest before cloning. The preparation
   token is informational; callers must not inject it or assume it stays unchanged.

   Keyed preparation stops database-local Timescale workers after installing the
   extensions. Publication opens a separate administrative candidate connection
   after the application-role Repo stops, seals new connections, and calls
   `_timescaledb_functions.stop_background_workers()` before closing that session.
   An affirmative acknowledgement and a bounded zero-backend check are both
   required. This does not set restore mode, broaden template cloning privileges,
   disable workers cluster-wide, or terminate arbitrary clients. A missing control
   function, denied privilege, negative acknowledgement, or drain timeout fails
   closed. A server/launcher restart during construction can still require recovery;
   never bypass an active-connection refusal.

3. Clone the ordinary integration lanes:

   ```text
   bazel run -c opt --config=ci --//build:enable_integration_tests --//build:run_id=example01 //rust/integration-db:provision_generation
   ```

   For the large-ingestion shard, use the separate target:

   ```text
   bazel run -c opt --config=ci --//build:enable_integration_tests --//build:run_id=example01 //rust/integration-db:provision_generation_large_ingestion
   ```

   Successful output has `status: "cloned"`, `digest`, and `lease_id`. Each clone
   checks readiness and renews the lease under the generation lock. Shard lists
   come from the target declarations. There is no legacy-template fallback.
   Provisioning can replace an existing disposable clone for that run, so do not
   invoke it while that run's suite is active. A multi-shard failure may leave
   earlier clones; an absent success record must not be treated as all-or-nothing
   rollback.

4. Run the intended guarded suites against the matching run's clones. After they
   stop, use the existing disposable database teardown for that run, then release
   its generation lease:

   ```text
   bazel run -c opt --config=ci --//build:enable_integration_tests --//build:run_id=example01 //rust/integration-db:teardown_db
   bazel run -c opt --config=ci --//build:enable_integration_tests --//build:run_id=example01 //rust/integration-db:release_generation
   ```

   Lease release returns `status: "released"`, `digest`, and `lease_id`. It deletes
   only that lease, not the generation or its clones. Release is safe to repeat;
   success does not prove a lease previously existed. Ensure failure handling also
   tears down owned clones and releases the lease once the run no longer needs it.

## Resource policy and cleanup

The declared `build/schema_template/policy.json` currently sets these limits:

| Field | Value | Meaning |
| --- | --- | --- |
| `max_generations` | 16 | Maximum registered generations during allocation |
| `max_concurrent_builders` | 1 | Maximum registered `building` generations |
| `max_total_bytes` | 21474836480 | 20 GiB aggregate template storage budget |
| `retention_seconds` | 86400 | Minimum inactivity before cleanup eligibility |
| `lease_seconds` | 7200 | Lease duration after preparation or clone renewal |
| `lock_timeout_seconds` | 300 | Bounded coordination wait; also used for administrative statements |

Leases are renewed by operations; there is no background heartbeat in these
targets. Re-run preparation to renew a ready generation if a long gap precedes
cloning. Clones are independent once created. Generation age alone never overrides
an active lease or connection.

Storage is checked before allocation and again before publication, not enforced as
a continuous disk quota. Allocation counts databases with the template prefix,
including unregistered ones; this does not authorize their deletion. A candidate
that exceeds the publication budget remains unpublished. Policy edits change the
manifest identity and require review and qualification.

Run cleanup separately from ordinary teardown:

```text
bazel run -c opt --config=ci --//build:enable_integration_tests //rust/integration-db:cleanup_generations
```

This returns a JSON array of removed database names; `[]` means nothing was
removed, not that capacity is available. Cleanup selects expired registered
generations, tries their coordination locks, rechecks ownership and retention, and
skips busy, connected, or actively leased entries. It drops only the exact
registered database, without force, verifies its absence in the catalog, then
removes the registry record. Legacy and unregistered databases are not cleanup
candidates.

Every active workflow runs the ordinary scratch sweep and this registry-owned
cleanup before generation preparation. The ordinary reaper unconditionally excludes
the entire `sr_tpl_` namespace. It can reclaim abandoned run clones but cannot race
registry ownership or force-drop a generation. This separation keeps malformed or
unregistered reserved names fail-closed while allowing eligible registered
generations to be reclaimed under their coordination locks.

## Failure recovery

- On an interrupted or partial build, stop the failed worker and establish that
  it no longer owns a live connection. Re-run `prepare_generation` for the same
  manifest. Under the generation lock it can rebuild only the matching registered
  `building` database and fence older builders with a new token. A lease blocks
  cleanup but does not prevent this registered build recovery. Do not retry the
  migrator directly against a partial ledger.
- On lock timeout or active connections, investigate the owning run and allow it
  to finish or shut down normally. Never force-drop a template or terminate
  unrelated sessions to bypass coordination.
- On capacity failure, finish or recover existing builders, release completed
  runs' leases, and run guarded cleanup after retention permits it. Do not evict
  active generations or raise limits merely to conceal a failed construction.
- On an unregistered database with the expected name, identity mismatch, or
  collision, stop and investigate registry/catalog ownership. Never adopt or
  `DROP` an unregistered template, manually insert ownership, or delete registry
  rows to make preparation proceed.
- On changed PostgreSQL major or required extension versions, fail reuse and
  qualify a new manifest/fixture contract. A `ready` row with a missing database
  or connections still enabled is also a failure, not permission to repair it
  in place. Do not mutate a published generation.

Inspect registry state and leases in the administrative `postgres` database and
the corresponding catalog/connection state through the approved fixture diagnostic
path. Never commit captured rows, logs, identifiers, or credentials. For this
keyed lifecycle the recovery entrypoint is `prepare_generation`, not the legacy
singleton target.

## Qualification and rollout gate

The manual `SchemaTemplateQualification` action normally generates a fresh run ID.
To recover an interrupted synthetic run, dispatch that action with the explicit
`SCHEMA_TEMPLATE_QUALIFICATION_RUN_ID` environment value from its prior log, only
after confirming that run has ended. The normal registry identity, ownership lock,
and no-active-connections checks still apply; this is not permission to reuse
another run's databases. Recovery is appropriate while the first synthetic
generation is still `building`; a run that published it needs separate scoped
cleanup rather than replaying the fresh-run assertion. Never commit a captured
run ID to the workflow. Check fixture Timescale worker capacity before dispatch:
the regression must observe a scheduler, and a worker-limit refusal is a failed
prerequisite, not permission to skip that assertion or raise cluster limits.

The caller cutover is releasable only after verifying that the deployed reaper
excludes generation databases and protects their registry ownership. Run guarded,
in-cluster checks for
cold full replay, warm reuse without migrator startup, concurrent divergent
synthetic migration sets, same-version edits, interrupted builders, stale fencing,
clone/cleanup races, lease expiry, capacity failure, and protected database refusal.
Check actual clone schema and migration ledgers, not just process exit status.

Also pass cold-baseline bootstrap qualification, which remains part of
`//elixir/serviceradar_core:large_ingestion_release_gate`, and measure construction
time, connections, and storage against the policy. Keep preparation outside measured
suite timing. These are required checks, not completed qualification claims.

If any of that evidence fails, revert the callers while retaining both template
families. Rollback must not copy a keyed generation into the legacy singleton or
broaden ordinary teardown rules.
