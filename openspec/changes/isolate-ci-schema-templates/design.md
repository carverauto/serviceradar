## Context

Rust template.rs and the Elixir template_env.exs preloader independently hardcode the same template name. prepare_template checks filename versions against schema_migrations; it cannot distinguish edits to an already-applied migration. Template creation, migration, and cloning are separate workflow steps. Locking only database creation cannot make that sequence atomic.

The pending parallelize-core-integration-tests proposal owns lane scheduling, disposable run databases, typed fixture configuration, and preflight outside the measured lifecycle. This change adds template identity and publication without changing those boundaries.

## Goals and Non-Goals

Give every checkout the schema defined by its declared inputs, reuse identical inputs across branches, and recover from interrupted builders. Keep connections, storage, and initialization concurrency bounded.

Application migrations, the ingestion sandbox fix in #4301, and snapshot-activation payload repair are separate work.

## Decisions

### One declared manifest

A Bazel target emits a versioned canonical manifest and SHA-256 digest as declared inputs to every template consumer. Include sorted relative migration paths and file bytes, baseline SQL and metadata, and declared schema-affecting construction code/configuration and dependency versions. Explicitly inventory helper modules used by migrations and bootstrap; hashing filenames alone is insufficient. Record PostgreSQL and extension compatibility identities, and reject incompatible fixture versions before reuse. Credentials, run ids, branch names, timestamps, and absolute checkout paths are excluded.

Rust and Elixir consume the same manifest rather than reimplementing hashing. Use a bounded database identifier derived from the digest and compare the full digest in metadata before reuse, so truncated-name collisions fail closed. Changes to any input represented by an existing baseline must invalidate reuse; the construction check must reject an inconsistent baseline rather than claiming an edited historical migration was executed.

### Private construction and atomic publication

Maintain a fixture-owned generation registry in the existing administrative fixture boundary, outside cloned application schemas. Store full manifest identity, candidate database, builder token, state, and lease metadata. Initialize registry versioning through a guarded Bazel target.

Preparation selects an existing ready generation or allocates the deterministic private database `sr_tpl_<first-48-digest-hex>`. Registry state, not a second candidate-name namespace, controls publication. Rust owns allocation and incomplete-candidate recovery. The Elixir builder rereads ownership under the generation lock and takes a new fencing token; it never trusts a token printed by an earlier command. The builder holds a session lock on the administrative `postgres` database across mutation and publication; all cooperating callers use that same database for coordination. Losing the ownership connection terminates the migration owner, and fencing prevents stale publication.

Cold keyed construction explicitly uses the policy's `full_replay` mode, as the application role. The current baseline metadata has a SQL checksum but no historical migration-content provenance. It cannot certify that an edited covered migration is represented by its SQL. Do not synthesize that provenance from today's files. Baseline bytes still invalidate the manifest conservatively; qualifying the separate cold-baseline path remains a rollout requirement, not a problem concealed by full replay.

After migration, verify expected migration versions in both directions, manifest identity, and required fixture initialization. Stop the Repo and disable database connections before marking the candidate ready. Published databases receive no further schema changes. A competing builder for the same digest waits with a bounded deadline or reuses the published result. Different digests use independent identities, subject to a configurable construction concurrency limit.

Registry publication is atomic; database creation is not transactional. An interrupted candidate therefore remains unpublished and cannot be cloned. Recovery takes its ownership lock, verifies the builder has ended, and discards or rebuilds only that candidate.

Keyed preparation quiesces Timescale workers after extension installation. At publication, use a separate administrative candidate connection after the application-role Repo stops, disable new connections, call the database-local `_timescaledb_functions.stop_background_workers()`, require its positive acknowledgement, close the control connection, and verify zero backends under a bounded deadline. Keep the generation ownership session throughout. Do not use cluster settings, restore mode, `IS_TEMPLATE` permission broadening, or arbitrary backend termination. The synthetic publisher must explicitly observe a running scheduler before testing this transition; ordinary clone flags and restore mode must remain unchanged.

### Pinning and cleanup

Each run acquires a renewable generation lease during preflight. Clone operations hold the same generation coordination lock used by cleanup, recheck readiness, and renew the lease before creating their disposable run database. Cleanup cannot select a generation in that critical section. Once clones exist, their lifecycle is independent of the source template.

Ordinary run teardown may delete only its disposable clones and release its own lease. Template cleanup is a separate guarded target, requiring registry ownership, an exact validated database identity, no active leases/builders/connections, and retention expiry. Never broaden the ordinary disposable-name matcher to include templates. Use explicit retention/count/size limits in typed configuration; at capacity, report actionable failure rather than evict an active generation.

Retain existing protected database exclusions, including the legacy singleton. Do not automatically delete or migrate the old template during transition.

### Workflow integration and rollout

Update prepare, conditional migration, readiness validation, provision, and cleanup callers together. Carry the pinned manifest identity through preflight and the measured lifecycle even where their run ids differ. Emit structured lifecycle status instead of relying on free-form migration-count substrings. Missing, incompatible, incomplete, and timed-out states must each fail explicitly.

First land opt-in generation targets while existing callers remain on the singleton. Deploy and verify all ordinary reaper exclusions for the entire `sr_tpl_` namespace before creating persistent generations. Start with cold construction on synthetic fixtures, then concurrent divergent schemas, then ordinary lanes and LargeIngestionGate. Keep full template preparation outside benchmark timing. Prove warm reuse skips the BEAM migrator. Only then switch existing callers together. Rollback reverts callers while preserving both template families; it does not copy keyed schemas into the legacy singleton.

## Alternatives

- Branch-named mutable templates still permit stale results after rebases or edits and duplicate identical schemas.
- Allowing only staging to advance one template cannot supply the schema of a divergent PR.
- Fresh database replay for every run isolates schemas but discards useful warm reuse.
- Cloning a compatible ancestor template could reduce cold cost, but requires per-input provenance and baseline compatibility. Defer that optimization until immutable cold construction is reliable.

## Risks and Validation

More schema variants consume disk and increase cold bootstrap frequency. Measure cold creation, warm reuse, connections, and storage against the existing fixture budget. Treat baseline shared-lock exhaustion as a rollout blocker requiring diagnosis; do not silently raise cluster limits or switch migration strategies to conceal it.

Acceptance uses invented migrations and data, two independently coordinated lifecycle processes, explicit deadlines, and database schema/ledger queries. A successful process exit alone does not establish isolation. The guarded lifecycle tests execute only in the in-cluster BuildBuddy workflow.
