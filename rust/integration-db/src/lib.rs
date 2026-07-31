/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Database lifecycle for the `serviceradar_core` integration suite.
//!
//! Replaces `scripts/reset-test-db.sh`, `scripts/drop-test-db.sh` and
//! `scripts/sweep-stale-core-test-dbs.sh`, so `.forgejo/workflows/elixir-integration-sr-core.yml`
//! invokes Bazel targets and nothing else.
//!
//! # Why Rust and not Elixir
//!
//! An `ex_unit_test` that depends on `serviceradar_core` costs 28.8-45.6s before it runs a
//! single test -- staging a 140-application ERL_LIBS tree, copying data, starting the BEAM
//! and loading the app. That was measured, not estimated: `unit_tests_external` ran zero
//! tests and still took that long. A `rust_test` in this repo starts in 0.1s.
//!
//! Provisioning and teardown are a handful of DDL statements, so paying the BEAM for them is
//! pure waste. Applying the 368 migrations is NOT here and cannot be: they are
//! `use Ecto.Migration` modules, and only `Ecto.Migrator` can execute them. That step stays
//! an Elixir target and pays the BEAM cost once.
//!
//! # Database naming
//!
//! The name is derived, never passed between steps. Provision, teardown and the suite each
//! recompute it from `GITHUB_RUN_ID` and `GITHUB_RUN_ATTEMPT`, which are constant for the
//! run, so there is no `GITHUB_ENV` handoff and no ordering assumption about who wrote it
//! first. The old shell embedded `date +%s`, which is exactly the kind of value that cannot
//! be recomputed by a later step.

use std::env;
use std::fs::File;
use std::io::BufReader;
use std::sync::Once;

use anyhow::{anyhow, bail, Context, Result};
use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::certs;
use srql::db::PgRustlsConnect;
use tokio::task::JoinHandle;
use tokio_postgres::{Client, Config as PgConfig, NoTls};

pub mod template;

/// Prefix every database this crate is willing to create or drop must carry.
///
/// Load-bearing, not cosmetic: [`assert_disposable`] refuses any other name, which is what
/// stops a misconfigured environment from pointing teardown or the sweep at the shared
/// fixture itself. Concurrent pull requests use that fixture.
pub const DISPOSABLE_PREFIX: &str = "sr_core_test_";

/// PostgreSQL's identifier limit. A name over this is silently truncated by the server,
/// which would make two runs collide on one database.
const MAX_IDENTIFIER_BYTES: usize = 63;

/// Extensions the schema depends on. Order matters only in that `age` must be present
/// before any graph is created.
const REQUIRED_EXTENSIONS: &[&str] = &[
    "pgcrypto",
    "pg_trgm",
    "citext",
    "timescaledb",
    "age",
    "postgis",
    "vector",
];

/// AGE graphs the application expects to exist.
const REQUIRED_GRAPHS: &[&str] = &["serviceradar_topology", "serviceradar", "platform_graph"];

/// rustls installs a process-wide crypto provider, and doing it twice panics.
static CRYPTO_PROVIDER: Once = Once::new();

fn ensure_crypto_provider() {
    CRYPTO_PROVIDER.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

/// The per-run database name, derived rather than passed.
///
/// `GITHUB_RUN_ID` and `GITHUB_RUN_ATTEMPT` are fixed for a run, so every step computes the
/// same name independently. Outside CI both are absent and the name falls back to a local
/// one, which keeps the crate usable against a developer fixture.
pub fn database_name() -> Result<String> {
    let name = match (env::var("GITHUB_RUN_ID"), env::var("GITHUB_RUN_ATTEMPT")) {
        (Ok(run_id), Ok(attempt)) => {
            for (label, value) in [("GITHUB_RUN_ID", &run_id), ("GITHUB_RUN_ATTEMPT", &attempt)] {
                if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                    bail!("{label} must be numeric, got {value:?}");
                }
            }
            format!("{DISPOSABLE_PREFIX}{run_id}_{attempt}")
        }
        _ => format!("{DISPOSABLE_PREFIX}local"),
    };

    if name.len() > MAX_IDENTIFIER_BYTES {
        bail!(
            "derived database name is {} bytes, over PostgreSQL's {MAX_IDENTIFIER_BYTES}-byte \
             limit: {name}",
            name.len()
        );
    }

    Ok(name)
}

/// The per-shard database name: [`database_name`] with a shard suffix.
///
/// The integration suite runs as parallel Bazel targets, and each needs its own database --
/// Ecto's SQL sandbox isolates concurrent tests inside one BEAM VM, not across OS processes,
/// so parallel shards against a single database deadlock. Must produce exactly the same
/// string as `test/db/integration_env.exs` derives from `SERVICERADAR_TEST_DB_SHARD`.
pub fn shard_database_name(shard: &str) -> Result<String> {
    if shard.is_empty() || !shard.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        bail!("shard name must be [a-z0-9_]+, got {shard:?}");
    }

    let name = format!("{}_{}", database_name()?, shard);

    if name.len() > MAX_IDENTIFIER_BYTES {
        bail!(
            "sharded database name is {} bytes, over PostgreSQL's {MAX_IDENTIFIER_BYTES}-byte \
             limit: {name}",
            name.len()
        );
    }

    Ok(name)
}

/// The URL the Elixir suite connects with: the fixture URL, repointed at [`database_name`].
///
/// Everything except the path is preserved, so query parameters such as `sslmode` survive.
pub fn database_url() -> Result<String> {
    let base = env::var("SRQL_TEST_DATABASE_URL")
        .context("SRQL_TEST_DATABASE_URL is required to derive the per-run database URL")?;
    let name = database_name()?;
    repoint_database(&base, &name)
}

fn repoint_database(url: &str, database: &str) -> Result<String> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| anyhow!("not a URL: {url}"))?;

    if !matches!(scheme, "postgres" | "postgresql" | "ecto") {
        bail!("unexpected scheme {scheme:?}; expected postgres, postgresql or ecto");
    }

    // Split authority from path, keeping any ?query intact.
    let (authority, tail) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx + 1..]),
        None => (rest, ""),
    };
    let query = tail.find('?').map(|idx| &tail[idx..]).unwrap_or("");

    Ok(format!("{scheme}://{authority}/{database}{query}"))
}

/// Refuse to touch anything that is not a per-run database.
pub fn assert_disposable(database: &str) -> Result<()> {
    if !database.starts_with(DISPOSABLE_PREFIX) {
        bail!("refusing to operate on {database:?}: expected a {DISPOSABLE_PREFIX}* database");
    }
    Ok(())
}

/// The admin URL, which must have rights to CREATE/DROP DATABASE and install extensions.
pub fn admin_url() -> Result<String> {
    env::var("SRQL_TEST_ADMIN_URL")
        .or_else(|_| env::var("SERVICERADAR_TEST_ADMIN_URL"))
        .context("SRQL_TEST_ADMIN_URL (or SERVICERADAR_TEST_ADMIN_URL) is required")
}

/// Connect with the admin credentials, optionally overriding the database.
///
/// The returned [`JoinHandle`] drives the connection; dropping it closes the socket, so it
/// has to outlive every query the caller makes.
pub async fn connect_admin(database: Option<&str>) -> Result<(Client, JoinHandle<()>)> {
    let mut config: PgConfig = admin_url()
        .context("admin URL unavailable")?
        .parse()
        .context("SRQL_TEST_ADMIN_URL is not a valid PostgreSQL connection string")?;

    if let Some(database) = database {
        config.dbname(database);
    }

    connect(config).await
}

async fn connect(config: PgConfig) -> Result<(Client, JoinHandle<()>)> {
    match tls_connector_from_env()? {
        Some(connector) => {
            let (client, connection) = config.connect(connector).await?;
            Ok((client, spawn_connection(connection)))
        }
        None => {
            let (client, connection) = config.connect(NoTls).await?;
            Ok((client, spawn_connection(connection)))
        }
    }
}

fn spawn_connection<S, T>(connection: tokio_postgres::Connection<S, T>) -> JoinHandle<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    T: tokio_postgres::tls::TlsStream + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres connection closed with error: {err}");
        }
    })
}

/// TLS from `PGSSLROOTCERT`, matching how the SRQL harness reaches the same fixture.
///
/// Absent root cert means plaintext, which is what a local docker fixture uses.
fn tls_connector_from_env() -> Result<Option<PgRustlsConnect>> {
    let Ok(root_cert) = env::var("PGSSLROOTCERT") else {
        return Ok(None);
    };
    if root_cert.is_empty() {
        return Ok(None);
    }

    ensure_crypto_provider();

    let mut reader =
        BufReader::new(File::open(&root_cert).context("failed to open PGSSLROOTCERT")?);
    let mut root_store = RootCertStore::empty();
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse PGSSLROOTCERT")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow!("invalid certificate in PGSSLROOTCERT"))?;
    }

    let config = ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();

    Ok(Some(PgRustlsConnect::new(
        config,
        env::var("PGSSLSERVERNAME").ok(),
    )))
}

pub(crate) async fn install_extensions(database: &str, owner: &str) -> Result<()> {
    let (client, _task) = connect_admin(Some(database)).await?;

    // Create the platform schema BEFORE any migration runs, or Ecto's bookkeeping table
    // moves between runs.
    //
    // config/test.exs sets search_path = "platform, public, ag_catalog" and
    // migration_default_prefix: "platform". On a database where `platform` does not exist
    // yet, the first migration's unqualified `schema_migrations` falls through the search
    // path and is created in `public`. Every later run then finds `platform` present, creates
    // a SECOND, empty `platform.schema_migrations`, concludes that nothing has been applied
    // and replays migration 1 -- which fails with `relation "edge_sites" already exists`.
    //
    // Observed exactly that: 97 rows in public.schema_migrations, 1 in platform's.
    //
    // The old flow never saw it because it dropped and recreated the database every run, so
    // there was never a second run against an existing schema. The template is long-lived and
    // migrated incrementally, so the location has to be stable -- and `platform` is where the
    // project's own convention puts it.
    client
        .batch_execute(&format!(
            "CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION {};",
            quote_ident(owner)
        ))
        .await
        .context("failed to create the platform schema")?;

    for extension in REQUIRED_EXTENSIONS {
        client
            .batch_execute(&format!(
                "CREATE EXTENSION IF NOT EXISTS {};",
                quote_ident(extension)
            ))
            .await
            .with_context(|| format!("failed to install extension {extension}"))?;
    }

    // AGE keeps its catalogue in ag_catalog, and the application user reaches it as a
    // non-superuser, so the grants are what make the graphs usable at all.
    for statement in [
        format!(
            "GRANT USAGE ON SCHEMA ag_catalog TO {};",
            quote_ident(owner)
        ),
        format!(
            "GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO {};",
            quote_ident(owner)
        ),
        format!(
            "GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO {};",
            quote_ident(owner)
        ),
        format!(
            "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO {};",
            quote_ident(owner)
        ),
    ] {
        client
            .batch_execute(&statement)
            .await
            .with_context(|| format!("failed to grant on ag_catalog: {statement}"))?;
    }

    create_graphs(&client).await
}

/// Create the AGE graphs, tolerating ones that already exist.
///
/// `create_graph` is not idempotent and raises when the graph is present. Catching the
/// exception is not enough on its own: AGE raises `graph "..." already exists` with an
/// errcode that is NOT `duplicate_schema`, which is what an earlier version of this function
/// assumed -- it only ever ran against a freshly created database, so the assumption was
/// never tested. The template is long-lived and this runs against it on every invocation, so
/// the existence check is the load-bearing part and the handler is only a race backstop.
///
/// `LOAD 'age'` and the search_path are session state, so they are set in the same batch.
async fn create_graphs(client: &Client) -> Result<()> {
    let graphs = REQUIRED_GRAPHS
        .iter()
        .map(|graph| quote_literal(graph))
        .collect::<Vec<_>>()
        .join(", ");

    client
        .batch_execute(&format!(
            "LOAD 'age';
             SET search_path = ag_catalog, pg_catalog, \"$user\", public;
             DO $$
             DECLARE
               graph_name text;
             BEGIN
               FOREACH graph_name IN ARRAY ARRAY[{graphs}] LOOP
                 IF NOT EXISTS (
                   SELECT 1 FROM ag_catalog.ag_graph WHERE name::text = graph_name
                 ) THEN
                   BEGIN
                     PERFORM ag_catalog.create_graph(graph_name);
                   EXCEPTION
                     WHEN duplicate_schema OR unique_violation THEN NULL;
                   END;
                 END IF;
               END LOOP;
             END
             $$;"
        ))
        .await
        .context("failed to create AGE graphs")
}

/// Drop every database belonging to this run, including all shards.
///
/// Matches `<database_name()>` and `<database_name()>_<shard>`. Returns the names dropped.
/// Driven by a query rather than the shard list so that a shard count changed between
/// provision and teardown still leaves nothing behind.
pub async fn teardown_run() -> Result<Vec<String>> {
    let base = database_name()?;
    assert_disposable(&base)?;

    let (admin, _task) = connect_admin(None).await?;

    let rows = admin
        .query(
            "SELECT datname FROM pg_database WHERE datname = $1 OR datname LIKE $2 ORDER BY 1;",
            &[&base, &like_prefix(&format!("{base}_"))],
        )
        .await
        .context("failed to list this run's databases")?;

    let mut dropped = Vec::new();

    for row in rows {
        let name: String = row.get(0);

        // The LIKE is already anchored on a disposable prefix; this is what makes a mistake
        // in the query non-destructive rather than merely unlikely.
        if assert_disposable(&name).is_err() {
            continue;
        }

        teardown(&name).await?;
        dropped.push(name);
    }

    Ok(dropped)
}

/// Drop one database. Equivalent to `scripts/drop-test-db.sh`.
pub async fn teardown(database: &str) -> Result<()> {
    assert_disposable(database)?;

    let (admin, _task) = connect_admin(None).await?;

    // FORCE terminates leftover backends; without it a connection the suite failed to close
    // keeps the drop blocked indefinitely.
    admin
        .batch_execute(&format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE);",
            quote_ident(database)
        ))
        .await
        .with_context(|| format!("failed to drop {database}"))?;

    Ok(())
}

/// Drop `sr_core_test_*` databases older than `max_age_secs`.
///
/// Equivalent to `scripts/sweep-stale-core-test-dbs.sh`. Runs that are cancelled or whose
/// runner dies never reach teardown, so without this the fixture accumulates databases.
/// Returns the names dropped.
pub async fn sweep_stale(max_age_secs: i64) -> Result<Vec<String>> {
    let (admin, _task) = connect_admin(None).await?;

    // pg_database has no creation timestamp, so age comes from the directory's mtime via
    // pg_stat_file on the database's path. That is what the shell script used too.
    let rows = admin
        .query(
            "SELECT datname \
             FROM pg_database \
             WHERE datname LIKE $1 \
               AND (pg_stat_file(pg_catalog.pg_relation_filepath('pg_database'))).modification \
                   < now() - make_interval(secs => $2::double precision)",
            &[&like_prefix(DISPOSABLE_PREFIX), &(max_age_secs as f64)],
        )
        .await
        .context("failed to list stale databases")?;

    let mut dropped = Vec::new();
    for row in rows {
        let name: String = row.get(0);

        // Belt and braces: the LIKE above already constrains this, but the guard is what
        // makes a mistake in the query non-destructive.
        if assert_disposable(&name).is_err() {
            continue;
        }

        match admin
            .batch_execute(&format!(
                "DROP DATABASE IF EXISTS {} WITH (FORCE);",
                quote_ident(&name)
            ))
            .await
        {
            Ok(()) => dropped.push(name),
            // A database another run is actively using is not this sweep's problem.
            Err(err) => eprintln!("could not drop stale database {name}: {err}"),
        }
    }

    Ok(dropped)
}

/// Quote an identifier. Doubling embedded quotes is what makes it injection-safe.
pub(crate) fn quote_ident(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

/// Quote a string literal.
pub(crate) fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// Escape a string for use as a literal prefix in `LIKE`.
///
/// `DISPOSABLE_PREFIX` contains underscores, and `_` is a single-character wildcard in
/// `LIKE`. Unescaped, `sr_core_test_%` also matches names like `srXcoreYtestZ...`. Nothing
/// is named that way today, so this is not a live bug -- but the sweep's job is dropping
/// databases, and a pattern that is looser than it looks is the wrong thing to leave in a
/// DROP path. [`assert_disposable`] still re-checks every name it returns.
pub(crate) fn like_prefix(value: &str) -> String {
    format!(
        "{}%",
        value
            .replace('\\', "\\\\")
            .replace('_', "\\_")
            .replace('%', "\\%")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_ident_doubles_embedded_quotes() {
        assert_eq!(quote_ident("plain"), "\"plain\"");
        assert_eq!(quote_ident("we\"ird"), "\"we\"\"ird\"");
    }

    #[test]
    fn quote_literal_doubles_embedded_apostrophes() {
        assert_eq!(quote_literal("plain"), "'plain'");
        assert_eq!(quote_literal("o'clock"), "'o''clock'");
    }

    #[test]
    fn like_prefix_escapes_the_underscore_wildcard() {
        // Without this the sweep's pattern would also match srXcoreYtestZ...
        assert_eq!(like_prefix(DISPOSABLE_PREFIX), "sr\\_core\\_test\\_%");
        assert_eq!(like_prefix("a%b"), "a\\%b%");
        assert_eq!(like_prefix("a\\b"), "a\\\\b%");
    }

    #[test]
    fn assert_disposable_rejects_the_shared_fixture() {
        assert!(assert_disposable("sr_core_test_123_1").is_ok());
        assert!(assert_disposable("serviceradar_web_ng_test").is_err());
        assert!(assert_disposable("postgres").is_err());
    }

    #[test]
    fn repoint_database_preserves_authority_and_query() {
        assert_eq!(
            repoint_database("postgres://u:p@host:5432/old?sslmode=require", "new").unwrap(),
            "postgres://u:p@host:5432/new?sslmode=require"
        );
        assert_eq!(
            repoint_database("postgresql://host/old", "new").unwrap(),
            "postgresql://host/new"
        );
    }

    #[test]
    fn repoint_database_rejects_a_foreign_scheme() {
        assert!(repoint_database("mysql://host/old", "new").is_err());
    }
}
