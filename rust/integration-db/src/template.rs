/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! A persistent template database, cloned per run instead of migrated per run.
//!
//! # Why
//!
//! `serviceradar_core` carries 368 migrations. Applying them is the only step in the
//! lifecycle that needs the BEAM, and it is by far the most expensive: `Ecto.Migrator` runs
//! them one transaction at a time, and the set only grows. Paying that on every CI run to
//! rebuild a schema that did not change is waste that compounds.
//!
//! So the migrations are applied once, to a long-lived `sr_core_template` database, and each
//! run gets its schema from:
//!
//! ```sql
//! CREATE DATABASE sr_core_test_<run> TEMPLATE sr_core_template;
//! ```
//!
//! PostgreSQL copies the template's files directly. That matters beyond speed: a
//! `pg_dump --schema-only` of this schema would NOT round-trip. TimescaleDB hypertables,
//! continuous aggregates and retention policies keep state in `_timescaledb_catalog`, and
//! AGE keeps graphs in `ag_catalog` plus a schema per graph. A physical copy carries all of
//! it because it never interprets any of it.
//!
//! # Staying current without a marker
//!
//! Whether the template needs migrating is decided by comparing the migration versions on
//! disk against `public.schema_migrations` inside the template -- the same predicate
//! `Ecto.Migrator` itself uses.
//!
//! Deliberately NOT a recorded digest or a "last built" marker. A marker is written by one
//! step and trusted by another, so it goes stale exactly when it matters: a migration that
//! fails half way would leave the marker either wrong or needing careful rollback. A version
//! set cannot go stale, because a migration that did not commit is not in
//! `schema_migrations`, and the next run sees it as pending again.
//!
//! Migrations are append-only, so the common case after adding one is that the template is
//! advanced by exactly that migration rather than rebuilt.
//!
//! # Who may WRITE to the template
//!
//! Only a run on trunk. This is the whole reason the lifecycle has a run base at all.
//!
//! The template is shared by every run and only ever ratchets FORWARD, so it is a CACHE of
//! trunk's schema and nothing else. It used to be advanced by whichever run reached
//! `//elixir/serviceradar_core:migrate_template` first -- and BazelCI triggers on
//! `pull_request` only, so in practice that was always a branch whose migrations were
//! UNMERGED. One such branch left seven migrations in the template that existed on no other
//! branch, and from that moment every other pull request cloned a schema it did not have the
//! code for. The check below caught it, correctly, and refused; the cost was that one
//! branch's pollution wedged everyone else's CI until that branch merged.
//!
//! So a branch's own migrations now go to `sr_core_test_<run>` -- the RUN BASE, created by
//! `//rust/integration-db:provision_base`, migrated by
//! `//elixir/serviceradar_core:migrate_run`, and used as the source the lane databases are
//! cloned from. The shared template is read, never written, by anything but trunk.
//!
//! And when the template is nonetheless ahead of this checkout, the run does not refuse: it
//! builds the run base from nothing instead ([`create_scratch`]) and reports loudly. A cache
//! that cannot be used is a cache miss, not an outage.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use tokio_postgres::Client;

use crate::{connect_admin, install_extensions, quote_ident, quote_literal};

/// The long-lived template. One per fixture, shared by every run.
///
/// Note it does NOT carry [`crate::DISPOSABLE_PREFIX`]: teardown and the sweep are only ever
/// allowed to drop `sr_core_test_*`, and the template must survive both.
pub const TEMPLATE_DATABASE: &str = "sr_core_template";

/// Guards template creation and migration against concurrent runs.
///
/// Advisory locks are local to the coordination database. Every cooperating caller
/// must lock on that same database, even when its DDL targets another database.
/// Arbitrary but fixed; "SRTP" in ASCII.
const TEMPLATE_LOCK_KEY: i64 = 0x5352_5450;

/// Ecto's bookkeeping table, unqualified. Which schema holds it is resolved at runtime by
/// [`schema_migrations_schema`] rather than hardcoded -- see that function for why.
const SCHEMA_MIGRATIONS: &str = "schema_migrations";

/// How long to keep retrying `CREATE DATABASE ... TEMPLATE` against a busy template.
///
/// Sized for the case that actually blocks: a concurrent run migrating the template. The
/// backoff caps at [`CLONE_RETRY_MAX`], so this is roughly
/// `CLONE_RETRIES * CLONE_RETRY_MAX` in the worst case -- long enough to outlast a migration,
/// short enough that a genuinely stuck connection is reported rather than hung on.
const CLONE_RETRIES: u32 = 30;
const CLONE_RETRY_INITIAL: Duration = Duration::from_millis(250);
const CLONE_RETRY_MAX: Duration = Duration::from_secs(15);

/// PostgreSQL `object_in_use`, raised when the template has other sessions connected.
const OBJECT_IN_USE: &str = "55006";

fn is_object_in_use(err: &tokio_postgres::Error) -> bool {
    err.code().map(|code| code.code()) == Some(OBJECT_IN_USE)
}

/// What [`ensure_template`] found or did, for the caller to log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemplateState {
    /// Did not exist; created empty with extensions and graphs. Every migration is pending.
    Created,
    /// Already present. Whether it differs from this checkout is [`migration_drift`]'s question.
    Existed,
}

/// Create the template database if it is absent, with extensions, AGE graphs and grants.
///
/// Idempotent, and safe to run concurrently: the advisory lock serialises the
/// check-then-create, which is otherwise a race between two runs starting together.
pub async fn ensure_template(owner: &str) -> Result<TemplateState> {
    let (admin, _task) = connect_admin(None).await?;

    lock(&admin).await?;

    let exists = database_exists(&admin, TEMPLATE_DATABASE).await?;

    let state = if exists {
        TemplateState::Existed
    } else {
        admin
            .batch_execute(&format!(
                "CREATE DATABASE {} OWNER {};",
                quote_ident(TEMPLATE_DATABASE),
                quote_ident(owner)
            ))
            .await
            .context("failed to create the template database")?;

        TemplateState::Created
    };

    // Unconditionally, not just on Created: an earlier run may have died between CREATE
    // DATABASE and the extensions, and install_extensions is itself idempotent.
    install_extensions(TEMPLATE_DATABASE, owner).await?;

    unlock(&admin).await?;

    Ok(state)
}

/// How a database's applied migrations differ from this checkout's, in BOTH directions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationDrift {
    /// On disk here, not applied there. The ordinary "you need to migrate" case.
    pub pending: Vec<i64>,
    /// Applied there, ABSENT from this checkout. See [`migration_drift_of`].
    pub extra_applied: Vec<i64>,
}

/// [`migration_drift_of`] against the shared template.
pub async fn migration_drift(migrations_dir: &Path) -> Result<MigrationDrift> {
    migration_drift_of(TEMPLATE_DATABASE, migrations_dir).await
}

/// Compares the migrations on disk against `database`'s `schema_migrations`, both ways.
///
/// The second direction is the one that used to go unasked. A database that is AHEAD of this
/// checkout runs the code under test against a FUTURE schema, and nothing noticed, because the
/// only question asked was "is anything PENDING?" -- and a behind-checkout's migrations are a
/// strict SUBSET of what is applied, so the answer is no.
///
/// Twice now that has surfaced as a scatter of constraint and undefined-column errors naming no
/// migration at all: once when `discovered_interfaces` was rekeyed, and again when
/// `network_credential_secret_versions` was reshaped. Each cost a full bisect to identify.
pub async fn migration_drift_of(database: &str, migrations_dir: &Path) -> Result<MigrationDrift> {
    let on_disk = versions_on_disk(migrations_dir)?;

    if on_disk.is_empty() {
        bail!(
            "no migrations found under {}; refusing to report a current database on the \
             strength of an empty directory",
            migrations_dir.display()
        );
    }

    let applied = applied_versions(database).await?;

    Ok(drift_between(&on_disk, &applied))
}

/// Whether the shared template may seed this checkout's run base.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateFitness {
    /// Nothing applied to the template is absent from this checkout. Clone it.
    Usable,
    /// The template carries migrations this checkout does not have. Do NOT clone it.
    Ahead { extra_applied: Vec<i64> },
}

/// Decide whether the template is a safe seed for the run base.
///
/// Only the extra-applied direction disqualifies it. A template that is merely BEHIND is the
/// ordinary case for a branch that adds migrations: the clone is seeded from it and the pending
/// migrations are then applied to the RUN BASE, never back to the shared template.
pub fn template_fitness(drift: &MigrationDrift) -> TemplateFitness {
    if drift.extra_applied.is_empty() {
        TemplateFitness::Usable
    } else {
        TemplateFitness::Ahead {
            extra_applied: drift.extra_applied.clone(),
        }
    }
}

/// The report printed when an ahead template is bypassed, naming every extra migration.
///
/// Naming them is the entire value of this text: what it replaces is a scatter of constraint and
/// undefined-column errors that name no migration, which has twice cost a full bisect. It is a
/// REPORT rather than a refusal because the run then builds its schema from its own migrations,
/// which is strictly more correct than cloning a future one -- and because refusing made one
/// branch's pollution wedge every other branch's CI until a human intervened.
pub fn ahead_report(template: &str, extra_applied: &[i64]) -> String {
    let versions = extra_applied
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>()
        .join(", ");

    format!(
        "template {template} is AHEAD of this checkout: {} migration(s) are applied that this \
         branch does not contain.\n\nExtra applied versions: {versions}\n\n\
         This run will NOT clone it. The run base is built from this checkout's own migrations \
         instead, which costs a full schema build for this run and leaves the shared template \
         untouched.\n\n\
         If those versions are on staging, merge or rebase -- your branch is behind. If they \
         belong to no merged branch, something advanced the shared template that should not \
         have; `bazel run //rust/integration-db:reset_template` drops it so the next trunk run \
         rebuilds it from staging.",
        extra_applied.len()
    )
}

/// Refuses unless `database`'s applied migrations match this checkout EXACTLY, both ways.
///
/// The gate in front of cloning the lane databases. By then the run base has been seeded and
/// migrated by this run alone, so either direction of drift is a broken invariant rather than a
/// state a branch can arrive in -- and cloning eight lanes from a half-built base would scatter
/// the failure across every lane instead of reporting it once, here.
pub fn ensure_current(database: &str, drift: &MigrationDrift) -> Result<()> {
    if drift.extra_applied.is_empty() && drift.pending.is_empty() {
        return Ok(());
    }

    let mut problems = Vec::new();

    if !drift.pending.is_empty() {
        problems.push(format!(
            "{} migration(s) still PENDING (starting at {}); \
             //elixir/serviceradar_core:migrate_run must run before the lanes are cloned",
            drift.pending.len(),
            drift.pending[0]
        ));
    }

    if !drift.extra_applied.is_empty() {
        problems.push(format!(
            "{} migration(s) applied that this checkout does not contain ({})",
            drift.extra_applied.len(),
            drift
                .extra_applied
                .iter()
                .map(i64::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    bail!(
        "run base {database} does not match this checkout: {}",
        problems.join("; ")
    )
}

/// The pure comparison, so both directions are testable without a database.
fn drift_between(on_disk: &BTreeSet<i64>, applied: &BTreeSet<i64>) -> MigrationDrift {
    MigrationDrift {
        pending: on_disk.difference(applied).copied().collect(),
        extra_applied: applied.difference(on_disk).copied().collect(),
    }
}

/// Versions recorded in `database`'s `schema_migrations`.
///
/// A database with no such table has had nothing applied yet, which is the state
/// [`ensure_template`] and [`create_scratch`] both leave behind on first creation.
async fn applied_versions(database: &str) -> Result<BTreeSet<i64>> {
    // Check for the database before connecting to it. Connecting to a database that does not
    // exist reports `FATAL: database "sr_core_template" does not exist`, which reads like a
    // fixture outage rather than "nothing has created it yet".
    {
        let (admin, _task) = connect_admin(None).await?;
        if !database_exists(&admin, database).await? {
            bail!("{database} does not exist; run //rust/integration-db:provision_base first");
        }
    }

    let (client, _task) = connect_admin(Some(database)).await?;

    let Some(schema) = schema_migrations_schema(&client, database).await? else {
        return Ok(BTreeSet::new());
    };

    let rows = client
        .query(
            &format!(
                "SELECT version FROM {}.{};",
                quote_ident(&schema),
                quote_ident(SCHEMA_MIGRATIONS)
            ),
            &[],
        )
        .await
        .context("failed to read applied migration versions")?;

    Ok(rows.into_iter().map(|row| row.get::<_, i64>(0)).collect())
}

/// Find the schema holding `schema_migrations`, and refuse to guess if there are two.
///
/// Not hardcoded, because where Ecto puts this table depends on what existed when the FIRST
/// migration ran. config/test.exs sets search_path = "platform, public, ag_catalog"; on a
/// database where `platform` does not exist yet the unqualified name falls through to
/// `public`, and on one where it does the table is created in `platform`.
///
/// Two of them is the failure this crate exists to prevent: a second, empty table means
/// "nothing applied", so the migrator replays from migration 1 and dies on an existing
/// relation. [`crate::install_extensions`] creates the platform schema up front precisely so
/// this cannot happen -- but a template built before that fix, or by hand, still can, and a
/// silent pick of the wrong one would replay 368 migrations against a full schema.
async fn schema_migrations_schema(client: &Client, database: &str) -> Result<Option<String>> {
    let rows = client
        .query(
            "SELECT n.nspname FROM pg_class c \
             JOIN pg_namespace n ON n.oid = c.relnamespace \
             WHERE c.relname = $1 AND c.relkind = 'r' \
             ORDER BY n.nspname;",
            &[&SCHEMA_MIGRATIONS],
        )
        .await
        .context("failed to locate schema_migrations")?;

    let schemas: Vec<String> = rows
        .into_iter()
        .map(|row| row.get::<_, String>(0))
        .collect();

    match schemas.len() {
        0 => Ok(None),
        1 => Ok(Some(schemas.into_iter().next().expect("length checked"))),
        _ => bail!(
            "{database} has schema_migrations in more than one schema ({}); Ecto would read the \
             empty one and replay every migration. For the shared template, \
             `bazel run //rust/integration-db:reset_template` drops it so the next trunk run \
             rebuilds it.",
            schemas.join(", ")
        ),
    }
}

/// Parse migration versions out of `<version>_<name>.exs` filenames.
fn versions_on_disk(migrations_dir: &Path) -> Result<BTreeSet<i64>> {
    let entries = fs::read_dir(migrations_dir)
        .with_context(|| format!("failed to read {}", migrations_dir.display()))?;

    let mut versions = BTreeSet::new();

    for entry in entries {
        let path = entry
            .context("failed to read a migrations directory entry")?
            .path();

        if path.extension().and_then(|ext| ext.to_str()) != Some("exs") {
            continue;
        }

        let Some(stem) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };

        // Ecto's own convention: everything before the first underscore is the version.
        let digits = stem.split('_').next().unwrap_or_default();

        let version: i64 = digits
            .parse()
            .with_context(|| format!("migration {stem} does not start with a numeric version"))?;

        if !versions.insert(version) {
            bail!("two migrations share version {version}");
        }
    }

    Ok(versions)
}

/// Create `database` as a physical copy of `source`.
///
/// Replaces the old create-then-install-extensions path: everything the source holds -- schema,
/// extensions, TimescaleDB catalog, AGE graphs -- arrives with the copy.
///
/// `source` is the shared template when seeding a run base, and the RUN BASE when cloning the
/// lane databases. Only the target is required to be disposable: the shared template is a legal
/// source and an illegal target, which is the asymmetry [`crate::assert_disposable`] encodes.
pub async fn clone_database(source: &str, database: &str, owner: &str) -> Result<()> {
    crate::assert_disposable(database)?;

    let (admin, _task) = connect_admin(None).await?;

    if !database_exists(&admin, source).await? {
        bail!(
            "{source} does not exist; run //rust/integration-db:provision_base before cloning \
             from it"
        );
    }

    // Terminate leftovers on the TARGET, then drop it: a retried attempt starts clean.
    terminate_backends(&admin, database).await?;

    admin
        .batch_execute(&format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE);",
            quote_ident(database)
        ))
        .await
        .context("failed to drop the pre-existing database")?;

    // CREATE DATABASE ... TEMPLATE refuses to run while ANY session is connected to the
    // source, failing with SQLSTATE 55006 (object_in_use).
    //
    // Three things cause that, and none should be fatal. Our own connection from the
    // pending-versions check closes asynchronously -- dropping a tokio_postgres Client
    // signals the connection task, but the server may not have processed the disconnect by
    // the time the next statement lands. A concurrent run may be migrating the shared
    // template, which takes as long as it takes. And when the source is this run's own base,
    // the BEAM that just migrated it may not have finished tearing its pool down.
    //
    // So: retry with backoff rather than terminate. Terminating backends on the source would
    // resolve the first case and corrupt the second, killing another run's migration half way
    // through.
    let statement = format!(
        "CREATE DATABASE {} TEMPLATE {} OWNER {};",
        quote_ident(database),
        quote_ident(source),
        quote_ident(owner)
    );

    let mut delay = CLONE_RETRY_INITIAL;
    let mut last_err = None;

    for attempt in 1..=CLONE_RETRIES {
        match admin.batch_execute(&statement).await {
            Ok(()) => return Ok(()),
            Err(err) if is_object_in_use(&err) => {
                eprintln!(
                    "{source} is in use (attempt {attempt}/{CLONE_RETRIES}); \
                     retrying in {delay:?}"
                );
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(CLONE_RETRY_MAX);
                last_err = Some(err);
            }
            Err(err) => {
                return Err(err)
                    .with_context(|| format!("failed to clone {database} from {source}"))
            }
        }
    }

    Err(last_err.expect("loop ran at least once")).with_context(|| {
        format!(
            "{source} was still in use after {CLONE_RETRIES} attempts; something is holding a \
             connection to it"
        )
    })
}

/// Create `database` empty, with the extensions, AGE graphs and grants a migrator needs.
///
/// The seed for a run base when the shared template cannot be cloned. Deliberately the same
/// state [`ensure_template`] leaves behind on first creation, so `SchemaBootstrap.classify/1`
/// reports `:empty` and the Elixir migrator takes the baseline path it already takes when the
/// template itself is built from nothing.
pub async fn create_scratch(database: &str, owner: &str) -> Result<()> {
    crate::assert_disposable(database)?;

    let (admin, _task) = connect_admin(None).await?;

    // A retried attempt starts clean, exactly as the clone path does.
    terminate_backends(&admin, database).await?;

    admin
        .batch_execute(&format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE);",
            quote_ident(database)
        ))
        .await
        .context("failed to drop the pre-existing database")?;

    admin
        .batch_execute(&format!(
            "CREATE DATABASE {} OWNER {};",
            quote_ident(database),
            quote_ident(owner)
        ))
        .await
        .with_context(|| format!("failed to create {database}"))?;

    install_extensions(database, owner).await
}

/// Drop the shared template, so the next trunk run rebuilds it from staging.
///
/// The recovery for a template that has diverged from trunk -- migrations applied that belong to
/// no merged branch, or a `schema_migrations` in two schemas. Nothing else may drop it:
/// [`crate::assert_disposable`] refuses the name, which is what keeps teardown and the sweep off
/// it, and this function is the single deliberate exception.
///
/// Does NOT terminate backends. A session on the template is either another run cloning from it
/// or a migration in flight, and killing the second leaves a half-applied schema -- the exact
/// state `//elixir/serviceradar_core:migrate_template` documents as unrecoverable. It retries
/// `object_in_use` on the same schedule as the clone path and then reports, so a busy template
/// delays the reset rather than corrupting a concurrent run.
pub async fn reset_template() -> Result<bool> {
    let (admin, _task) = connect_admin(None).await?;

    lock(&admin).await?;

    let result = drop_template_locked(&admin).await;

    unlock(&admin).await?;

    result
}

async fn drop_template_locked(admin: &Client) -> Result<bool> {
    if !database_exists(admin, TEMPLATE_DATABASE).await? {
        return Ok(false);
    }

    let statement = format!("DROP DATABASE {};", quote_ident(TEMPLATE_DATABASE));

    let mut delay = CLONE_RETRY_INITIAL;
    let mut last_err = None;

    for attempt in 1..=CLONE_RETRIES {
        match admin.batch_execute(&statement).await {
            Ok(()) => return Ok(true),
            Err(err) if is_object_in_use(&err) => {
                eprintln!(
                    "template {TEMPLATE_DATABASE} is in use (attempt {attempt}/{CLONE_RETRIES}); \
                     retrying in {delay:?}"
                );
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(CLONE_RETRY_MAX);
                last_err = Some(err);
            }
            Err(err) => {
                return Err(err).with_context(|| format!("failed to drop {TEMPLATE_DATABASE}"))
            }
        }
    }

    Err(last_err.expect("loop ran at least once")).with_context(|| {
        format!(
            "template {TEMPLATE_DATABASE} was still in use after {CLONE_RETRIES} attempts; \
             something is holding a connection to it"
        )
    })
}

async fn database_exists(admin: &Client, database: &str) -> Result<bool> {
    let row = admin
        .query_one(
            "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1);",
            &[&database],
        )
        .await
        .with_context(|| format!("failed to check whether {database} exists"))?;

    Ok(row.get(0))
}

pub(crate) async fn terminate_backends(admin: &Client, database: &str) -> Result<()> {
    admin
        .batch_execute(&format!(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
             WHERE datname = {} AND pid <> pg_backend_pid();",
            quote_literal(database)
        ))
        .await
        .with_context(|| format!("failed to terminate backends on {database}"))?;

    Ok(())
}

async fn lock(admin: &Client) -> Result<()> {
    admin
        .execute("SELECT pg_advisory_lock($1);", &[&TEMPLATE_LOCK_KEY])
        .await
        .context("failed to take the template advisory lock")?;

    Ok(())
}

async fn unlock(admin: &Client) -> Result<()> {
    admin
        .execute("SELECT pg_advisory_unlock($1);", &[&TEMPLATE_LOCK_KEY])
        .await
        .context("failed to release the template advisory lock")?;

    Ok(())
}

/// Locate the migrations directory, under Bazel runfiles or a plain `cargo test`.
pub fn migrations_dir() -> PathBuf {
    const REL: &str = "elixir/serviceradar_core/priv/repo/migrations";

    // bazel rust_test: cwd is the main-workspace runfiles root.
    let bazel = Path::new(REL);
    if bazel.is_dir() {
        return bazel.to_path_buf();
    }

    // The Bazel ecosystem's reference lookup. Replaces a hand-rolled `TEST_SRCDIR` + "_main"
    // join, which hardcoded the canonical repository name, could not find the tree under
    // `bazel run`, and could not work in manifest mode. Shared with `config::runfile`.
    if let Some(dir) = crate::config::runfile(REL).ok().filter(|p| p.is_dir()) {
        return dir;
    }

    // cargo test: climb out of rust/integration-db to the workspace root.
    //
    // std::env::var, not env!. The macro is evaluated at COMPILE time, so it bakes the
    // absolute path of the directory that built this crate into the library -- under RBE
    // that is /buildbuddy-execroot/..., which makes the artifact non-reproducible and is
    // rejected outright by rules_rs's process wrapper. Read at runtime instead: cargo sets
    // the variable when it runs the test, and Bazel never reaches this branch because the
    // two runfiles lookups above already resolved.
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        return Path::new(&manifest_dir).join("../..").join(REL);
    }
    PathBuf::from(REL)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn versions(v: &[i64]) -> BTreeSet<i64> {
        v.iter().copied().collect()
    }

    #[test]
    fn drift_reports_pending_when_the_checkout_is_ahead() {
        let drift = drift_between(&versions(&[1, 2, 3]), &versions(&[1, 2]));

        assert_eq!(drift.pending, vec![3]);
        assert!(drift.extra_applied.is_empty());
    }

    #[test]
    fn drift_reports_extra_applied_when_the_template_is_ahead() {
        // THE CASE THAT USED TO GO UNASKED. A behind-branch's migrations are a strict subset of
        // what is applied, so "is anything pending?" answers no while the schema is a future one.
        let drift = drift_between(&versions(&[1, 2]), &versions(&[1, 2, 3]));

        assert!(drift.pending.is_empty());
        assert_eq!(drift.extra_applied, vec![3]);
    }

    #[test]
    fn drift_reports_both_directions_at_once() {
        let drift = drift_between(&versions(&[1, 2, 4]), &versions(&[1, 3]));

        assert_eq!(drift.pending, vec![2, 4]);
        assert_eq!(drift.extra_applied, vec![3]);
    }

    #[test]
    fn an_ahead_template_is_unusable_even_when_some_migrations_are_also_pending() {
        // Divergent branches produce drift in BOTH directions at once. The extra-applied side
        // alone decides usability; a coexisting pending set must not mask it.
        let drift = drift_between(&versions(&[1, 2, 4]), &versions(&[1, 3]));

        assert_eq!(drift.pending, vec![2, 4]);
        assert_eq!(
            template_fitness(&drift),
            TemplateFitness::Ahead {
                extra_applied: vec![3]
            }
        );
    }

    #[test]
    fn ahead_report_names_every_extra_migration_and_the_recovery() {
        let drift = drift_between(&versions(&[1]), &versions(&[1, 20_260_830_220_000, 99]));

        let TemplateFitness::Ahead { extra_applied } = template_fitness(&drift) else {
            panic!("a template ahead of the checkout must be reported as ahead");
        };

        let message = ahead_report("sr_core_template", &extra_applied);

        // Naming them is the whole point: it is what replaces the bisect.
        assert!(message.contains("20260830220000"), "message: {message}");
        assert!(message.contains("99"), "message: {message}");
        assert!(message.contains("2 migration(s)"), "message: {message}");
        assert!(
            message.contains("AHEAD of this checkout"),
            "message: {message}"
        );
        // The recovery for the case the versions belong to no merged branch. Without it the
        // report says what is wrong and not how the shared state gets repaired.
        assert!(message.contains("reset_template"), "message: {message}");
    }

    #[test]
    fn a_template_that_is_merely_behind_is_still_usable() {
        // PENDING is the ordinary case for a branch that ADDS migrations. The clone is seeded
        // from the template and the pending migrations are applied to the run base afterwards,
        // so refusing here would stop every migration-bearing branch from testing at all.
        let drift = drift_between(&versions(&[1, 2, 3]), &versions(&[1]));

        assert!(!drift.pending.is_empty());
        assert_eq!(template_fitness(&drift), TemplateFitness::Usable);
    }

    #[test]
    fn a_run_base_must_be_exactly_current_before_the_lanes_are_cloned() {
        // Pending is fatal HERE even though it is ordinary for the template: by this point the
        // run has seeded and migrated its own base, so anything outstanding means the migrate
        // step did not run, and eight lanes would be cloned from a half-built schema.
        let behind = drift_between(&versions(&[1, 2, 3]), &versions(&[1]));
        let message = ensure_current("sr_core_test_abcd1234", &behind)
            .expect_err("a run base with pending migrations must be refused")
            .to_string();

        assert!(
            message.contains("2 migration(s) still PENDING"),
            "{message}"
        );
        assert!(message.contains("migrate_run"), "{message}");

        let ahead = drift_between(&versions(&[1]), &versions(&[1, 7]));
        let message = ensure_current("sr_core_test_abcd1234", &ahead)
            .expect_err("a run base ahead of the checkout must be refused")
            .to_string();

        assert!(message.contains("7"), "{message}");

        let current = drift_between(&versions(&[1, 2]), &versions(&[1, 2]));
        assert!(ensure_current("sr_core_test_abcd1234", &current).is_ok());
    }

    #[test]
    fn an_exactly_matching_template_has_no_drift_either_way() {
        let drift = drift_between(&versions(&[1, 2, 3]), &versions(&[1, 2, 3]));

        assert!(drift.pending.is_empty());
        assert!(drift.extra_applied.is_empty());
    }

    #[tokio::test]
    async fn an_empty_migrations_directory_is_refused_before_any_connection() {
        // NOT VACUOUS as a database test: the empty-directory check runs before the template is
        // contacted, so this fails for the stated reason rather than for want of a fixture.
        let dir = scratch("empty_drift");

        let error = migration_drift(&dir)
            .await
            .expect_err("an empty migrations directory must be refused");

        assert!(
            error.to_string().contains("no migrations found under"),
            "unexpected error: {error}"
        );
    }

    fn write(dir: &Path, name: &str) {
        fs::write(dir.join(name), "").expect("failed to write fixture migration");
    }

    fn scratch(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sr_template_versions_{label}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("failed to create scratch dir");
        dir
    }

    #[test]
    fn versions_on_disk_parses_the_leading_timestamp() {
        let dir = scratch("parse");
        write(&dir, "20260117080000_bootstrap_extensions.exs");
        write(&dir, "20260117090000_rebuild_schema.exs");

        let versions = versions_on_disk(&dir).expect("parse failed");

        assert_eq!(
            versions.into_iter().collect::<Vec<_>>(),
            vec![20260117080000, 20260117090000]
        );
    }

    #[test]
    fn versions_on_disk_ignores_non_exs_files() {
        let dir = scratch("ignore");
        write(&dir, "20260117080000_bootstrap.exs");
        write(&dir, "README.md");
        write(&dir, ".keep");

        let versions = versions_on_disk(&dir).expect("parse failed");

        assert_eq!(versions.len(), 1);
    }

    #[test]
    fn versions_on_disk_rejects_a_non_numeric_version() {
        let dir = scratch("bad");
        write(&dir, "not_a_version.exs");

        assert!(versions_on_disk(&dir).is_err());
    }

    #[test]
    fn the_template_is_not_disposable() {
        // Load-bearing: teardown and the sweep both refuse anything this rejects, which is
        // what keeps them from dropping the template out from under a concurrent run.
        assert!(crate::assert_disposable(TEMPLATE_DATABASE).is_err());
    }
}
