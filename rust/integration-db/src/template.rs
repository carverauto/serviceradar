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
/// Advisory locks are cluster-wide rather than per-database, which is what makes this usable
/// from a session connected to `postgres` to guard work happening in another database.
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
    /// Already present. Whether it is current is [`pending_versions`]' question.
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

/// Migration versions present on disk but not yet applied to the template.
///
/// Empty means the template is current and the Elixir migrator has nothing to do, which is
/// what lets the workflow skip starting the BEAM at all.
pub async fn pending_versions(migrations_dir: &Path) -> Result<Vec<i64>> {
    let on_disk = versions_on_disk(migrations_dir)?;

    if on_disk.is_empty() {
        bail!(
            "no migrations found under {}; refusing to report a current template on the \
             strength of an empty directory",
            migrations_dir.display()
        );
    }

    let applied = applied_versions().await?;

    Ok(on_disk.difference(&applied).copied().collect())
}

/// Versions recorded in the template's `schema_migrations`.
///
/// A template with no such table has had nothing applied yet, which is the state
/// [`ensure_template`] leaves behind on first creation.
async fn applied_versions() -> Result<BTreeSet<i64>> {
    // Check for the database before connecting to it. Connecting to a database that does not
    // exist reports `FATAL: database "sr_core_template" does not exist`, which reads like a
    // fixture outage rather than "nothing has created the template yet".
    {
        let (admin, _task) = connect_admin(None).await?;
        if !database_exists(&admin, TEMPLATE_DATABASE).await? {
            bail!(
                "template {TEMPLATE_DATABASE} does not exist; run \
                 //rust/integration-db:prepare_template first"
            );
        }
    }

    let (client, _task) = connect_admin(Some(TEMPLATE_DATABASE)).await?;

    let Some(schema) = schema_migrations_schema(&client).await? else {
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
async fn schema_migrations_schema(client: &Client) -> Result<Option<String>> {
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
            "template {TEMPLATE_DATABASE} has schema_migrations in more than one schema ({}); \
             Ecto would read the empty one and replay every migration. Drop the template and \
             let //rust/integration-db:prepare_template rebuild it.",
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

/// Create `database` as a physical copy of the template.
///
/// Replaces the old create-then-install-extensions path: everything the template holds --
/// schema, extensions, TimescaleDB catalog, AGE graphs -- arrives with the copy.
pub async fn clone_from_template(database: &str, owner: &str) -> Result<()> {
    crate::assert_disposable(database)?;

    let (admin, _task) = connect_admin(None).await?;

    if !database_exists(&admin, TEMPLATE_DATABASE).await? {
        bail!(
            "template {TEMPLATE_DATABASE} does not exist; run //rust/integration-db:ensure_template \
             and //elixir/serviceradar_core:migrate_template first"
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
    // Two things cause that, and neither should be fatal. Our own connection from the
    // pending-versions check closes asynchronously -- dropping a tokio_postgres Client
    // signals the connection task, but the server may not have processed the disconnect by
    // the time the next statement lands. And a concurrent run may be migrating the template,
    // which takes as long as it takes.
    //
    // So: retry with backoff rather than terminate. Terminating backends on the template
    // would resolve the first case and corrupt the second, killing another run's migration
    // half way through.
    let statement = format!(
        "CREATE DATABASE {} TEMPLATE {} OWNER {};",
        quote_ident(database),
        quote_ident(TEMPLATE_DATABASE),
        quote_ident(owner)
    );

    let mut delay = CLONE_RETRY_INITIAL;
    let mut last_err = None;

    for attempt in 1..=CLONE_RETRIES {
        match admin.batch_execute(&statement).await {
            Ok(()) => return Ok(()),
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
                return Err(err).with_context(|| {
                    format!("failed to clone {database} from template {TEMPLATE_DATABASE}")
                })
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
