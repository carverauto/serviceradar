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

use std::borrow::Cow;
use std::env;
use std::io::{BufReader, Cursor};
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

/// Find disposable databases whose own data-directory marker is older than the cutoff.
///
/// Every integration clone uses pg_default. Restricting the query to that tablespace is safer
/// than guessing PostgreSQL's versioned external-tablespace path. Most importantly, the path is
/// derived from each candidate database's OID, and PG_VERSION is written when CREATE DATABASE
/// creates that directory but is not touched by ordinary relation activity.
/// `pg_relation_filepath('pg_database')` names one shared catalog file and therefore gives every
/// database the same all-or-none age.
const STALE_DATABASE_QUERY: &str = "SELECT d.datname \
     FROM pg_database AS d \
     JOIN pg_tablespace AS t ON t.oid = d.dattablespace \
     WHERE d.datname LIKE $1 \
       AND t.spcname = 'pg_default' \
       AND (pg_stat_file(format('base/%s/PG_VERSION', d.oid), true)).modification \
           < now() - make_interval(secs => $2::double precision)";

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
    if shard.is_empty()
        || !shard
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
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
    require_verified_tls(&base, "SRQL_TEST_DATABASE_URL")?;
    let name = database_name()?;
    repoint_database(&base, &name)
}

/// Refuse a fixture DSN that does not demand verified TLS.
///
/// This used to be a property of the CREDENTIAL PIPELINE rather than of the code:
/// `buildbuddy_setup_fixture_env.sh` rewrote `sslmode=verify-full` into whatever DSN it was
/// handed, so the guarantee held only for callers that went through the script. A DSN that
/// arrives straight from a secret store -- which is the whole point of storing it there --
/// bypassed it.
///
/// A missing `sslmode` is not a loud failure, which is what makes it worth a hard error:
/// tokio-postgres then defaults to `Prefer`, which PERMITS A PLAINTEXT FALLBACK, and Postgrex
/// historically used `verify_none` even with a CA present. The fixture password crosses the
/// network in the clear and every test still passes. Fail to connect instead.
fn require_verified_tls(url: &str, variable: &str) -> Result<()> {
    let sslmode = url
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or_default()
        .split('&')
        .find_map(|parameter| {
            let (key, value) = parameter.split_once('=')?;
            key.eq_ignore_ascii_case("sslmode").then_some(value)
        });

    match sslmode {
        Some(value) if value.eq_ignore_ascii_case("verify-full") => Ok(()),
        Some(value) => bail!(
            "{variable} sets sslmode={value}, but the srql fixture requires sslmode=verify-full. \
             Fix the stored secret rather than weakening this check."
        ),
        None => bail!(
            "{variable} carries no sslmode, but the srql fixture requires sslmode=verify-full. \
             Without it tokio-postgres defaults to Prefer and may fall back to plaintext. \
             Append ?sslmode=verify-full to the stored secret."
        ),
    }
}

/// Remove every credential-bearing URL component before writing a database endpoint to logs.
///
/// PostgreSQL accepts passwords in either userinfo or the query string, so stripping only the
/// text before `@` is insufficient.
pub fn redacted_database_url(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else {
        return "<unparseable>".to_string();
    };
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    let authority_and_path = &rest[..end];

    match authority_and_path.rsplit_once('@') {
        Some((_, endpoint)) => format!("{scheme}://***@{endpoint}"),
        None => format!("{scheme}://{authority_and_path}"),
    }
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

/// The role that owns the template database and every clone taken from it.
///
/// Derived from `SRQL_TEST_DATABASE_URL`, because it MUST be the role the suite connects as:
/// the tests run as the application user, and a database owned by anyone else fails on the
/// first DDL they attempt.
///
/// `scripts/reset-test-db.sh` took the owner from that DSN's user and refused to run without
/// one. Porting it to Rust replaced that with a hardcoded `"serviceradar"` -- a name the
/// shared fixture has never had. Its roles are `srql` (the application role, from
/// `srql-test-db-credentials`) and `srql_hydra` (admin); there is no `serviceradar`, and every
/// database on it is owned by `srql`, which is exactly what the shell script produced.
///
/// So `CREATE DATABASE ... OWNER serviceradar` failed with `role "serviceradar" does not
/// exist`, naming a role nothing in the configuration ever asked for -- which reads like a
/// missing grant on the fixture rather than an assumption in this crate.
///
/// `SERVICERADAR_TEST_DATABASE_OWNER` still overrides, for a fixture that deliberately
/// separates the owning role from the connecting one.
pub fn database_owner() -> Result<String> {
    match env::var("SERVICERADAR_TEST_DATABASE_OWNER") {
        Ok(owner) if !owner.is_empty() => return Ok(owner),
        _ => {}
    }

    let url = env::var("SRQL_TEST_DATABASE_URL")
        .context("SRQL_TEST_DATABASE_URL is required to derive the test database owner")?;

    owner_from_url(&url)
}

fn owner_from_url(url: &str) -> Result<String> {
    let config = parse_pg_config(url, "SRQL_TEST_DATABASE_URL")?;

    config.get_user().map(str::to_string).context(
        "SRQL_TEST_DATABASE_URL must include a user: it names the role that owns the \
         per-run test databases. Set SERVICERADAR_TEST_DATABASE_OWNER to choose a \
         different owner explicitly.",
    )
}

/// The admin URL, which must have rights to CREATE/DROP DATABASE and install extensions.
pub fn admin_url() -> Result<String> {
    let url = env::var("SRQL_TEST_ADMIN_URL")
        .or_else(|_| env::var("SERVICERADAR_TEST_ADMIN_URL"))
        .context("SRQL_TEST_ADMIN_URL (or SERVICERADAR_TEST_ADMIN_URL) is required")?;
    require_verified_tls(&url, "SRQL_TEST_ADMIN_URL")?;

    Ok(url)
}

/// Connect with the admin credentials, optionally overriding the database.
///
/// The returned [`JoinHandle`] drives the connection; dropping it closes the socket, so it
/// has to outlive every query the caller makes.
pub async fn connect_admin(database: Option<&str>) -> Result<(Client, JoinHandle<()>)> {
    let admin_url = admin_url().context("admin URL unavailable")?;
    let mut config = parse_pg_config(&admin_url, "SRQL_TEST_ADMIN_URL")?;

    if let Some(database) = database {
        config.dbname(database);
    }

    connect(config).await
}

/// Parse a libpq-style URL with the subset of SSL modes understood by `tokio-postgres`.
///
/// The fixture DSNs are also consumed by Ecto/Postgrex, where `verify-ca` and `verify-full`
/// are meaningful and turn peer verification on. `tokio-postgres` accepts only `disable`,
/// `prefer`, and `require`; rejecting the shared DSN before our rustls connector sees it made
/// the Rust lifecycle incompatible with the verified Elixir connection. Map the two verified
/// libpq modes to `require` for this parser only. [`tls_connector_from_env`] still supplies the
/// fixture CA, and `PGSSLSERVERNAME` preserves hostname verification for NodePort addresses.
fn parse_pg_config(url: &str, variable: &str) -> Result<PgConfig> {
    normalize_sslmode_for_tokio_postgres(url)
        .parse()
        .with_context(|| format!("{variable} is not a valid PostgreSQL connection string"))
}

fn normalize_sslmode_for_tokio_postgres(url: &str) -> Cow<'_, str> {
    let Some((base, query)) = url.split_once('?') else {
        return Cow::Borrowed(url);
    };

    let must_normalize = query.split('&').any(|parameter| {
        let Some((key, value)) = parameter.split_once('=') else {
            return false;
        };

        key.eq_ignore_ascii_case("sslmode")
            && (value.eq_ignore_ascii_case("verify-ca")
                || value.eq_ignore_ascii_case("verify-full"))
    });

    if !must_normalize {
        return Cow::Borrowed(url);
    }

    let normalized = query
        .split('&')
        .map(|parameter| {
            let Some((key, value)) = parameter.split_once('=') else {
                return Cow::Borrowed(parameter);
            };

            if key.eq_ignore_ascii_case("sslmode")
                && (value.eq_ignore_ascii_case("verify-ca")
                    || value.eq_ignore_ascii_case("verify-full"))
            {
                Cow::Owned(format!("{key}=require"))
            } else {
                Cow::Borrowed(parameter)
            }
        })
        .collect::<Vec<_>>()
        .join("&");

    Cow::Owned(format!("{base}?{normalized}"))
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
/// The fixture CA as PEM bytes, preferring the certificate ITSELF over a path to it.
///
/// `SRQL_TEST_DATABASE_CA_CERT` carries the PEM; `PGSSLROOTCERT` carries a filesystem path.
/// The content form is independent of the caller's path namespace and therefore works inside
/// the runner-local Bazel sandbox as well as under any future execution placement.
///
/// The CA cannot become a declared Bazel input instead: it is a CNPG cluster cert on a 90-day
/// rotation (the current one is valid 2026-06-02..2026-08-31), so a committed copy would
/// expire on a calendar rather than on a change. Content-in-env keeps the rotating trust root
/// available without coupling the action to a workstation or workflow-runner path.
///
/// The path form is kept as a fallback for a developer pointing at a local fixture by file.
fn ca_pem_from_env() -> Result<Option<Vec<u8>>> {
    if let Ok(pem) = env::var("SRQL_TEST_DATABASE_CA_CERT") {
        if !pem.trim().is_empty() {
            return Ok(Some(pem.into_bytes()));
        }
    }

    match env::var("PGSSLROOTCERT") {
        Ok(path) if !path.is_empty() => {
            Ok(Some(std::fs::read(&path).with_context(|| {
                format!("failed to open PGSSLROOTCERT {path:?}")
            })?))
        }
        _ => Ok(None),
    }
}

fn tls_connector_from_env() -> Result<Option<PgRustlsConnect>> {
    let Some(pem) = ca_pem_from_env()? else {
        return Ok(None);
    };

    ensure_crypto_provider();

    let mut reader = BufReader::new(Cursor::new(pem));
    let mut root_store = RootCertStore::empty();
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse the fixture CA certificate")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow!("invalid certificate in the fixture CA"))?;
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

    create_graphs(&client).await?;
    own_graph_schemas(&client, owner).await
}

/// Hand the per-graph schemas, and everything AGE created inside them, to `owner`.
///
/// `ag_catalog.create_graph` makes a SCHEMA per graph and puts each label's table in it. The
/// grants above cover `ag_catalog` only, so the schemas stayed owned by the admin role that
/// ran `create_graph` and the application user could not even look inside one:
///
///   ERROR 42501 (insufficient_privilege) permission denied for schema platform_graph
///
/// raised by `SELECT to_regclass('platform_graph."Device"')` in migration
/// 20260622210000_add_age_platform_graph_property_indexes.
///
/// GRANT is not sufficient here. That migration goes on to CREATE INDEX on the label table,
/// and index creation requires OWNERSHIP -- no combination of GRANT confers it. So ownership
/// is transferred rather than privileges widened.
///
/// Applied after create_graphs rather than by creating the graphs under `SET ROLE`, because
/// this also has to repair a template whose graphs predate this function. It is idempotent:
/// re-running against already-correct ownership is a no-op, and a graph that does not exist
/// is skipped.
async fn own_graph_schemas(client: &Client, owner: &str) -> Result<()> {
    let graphs = REQUIRED_GRAPHS
        .iter()
        .map(|graph| quote_literal(graph))
        .collect::<Vec<_>>()
        .join(", ");
    let owner_literal = quote_literal(owner);

    client
        .batch_execute(&format!(
            "DO $$
             DECLARE
               graph_name text;
               obj record;
             BEGIN
               FOREACH graph_name IN ARRAY ARRAY[{graphs}] LOOP
                 IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = graph_name) THEN
                   EXECUTE format('ALTER SCHEMA %I OWNER TO %I', graph_name, {owner_literal});
                   FOR obj IN
                     SELECT c.relname AS name, c.relkind AS kind
                     FROM pg_class c
                     JOIN pg_namespace n ON n.oid = c.relnamespace
                     WHERE n.nspname = graph_name
                       AND c.relkind IN ('r', 'p', 'S')
                       -- A sequence OWNED BY a column cannot be reowned on its own:
                       --   cannot change owner of sequence \"_ag_label_edge_id_seq\"
                       --   DETAIL: Sequence is linked to table \"_ag_label_edge\"
                       -- It follows its table's owner, so the ALTER TABLE below already
                       -- moves it. Only free-standing sequences need handling here.
                       AND NOT (
                         c.relkind = 'S'
                         AND EXISTS (
                           SELECT 1
                           FROM pg_depend d
                           WHERE d.classid = 'pg_class'::regclass
                             AND d.objid = c.oid
                             AND d.deptype IN ('a', 'i')
                         )
                       )
                     -- Tables before sequences, so a sequence is already carried by its
                     -- table by the time the sequence branch could look at it.
                     ORDER BY (c.relkind = 'S'), c.relname
                   LOOP
                     IF obj.kind = 'S' THEN
                       EXECUTE format(
                         'ALTER SEQUENCE %I.%I OWNER TO %I',
                         graph_name, obj.name, {owner_literal}
                       );
                     ELSE
                       EXECUTE format(
                         'ALTER TABLE %I.%I OWNER TO %I',
                         graph_name, obj.name, {owner_literal}
                       );
                     END IF;
                   END LOOP;
                 END IF;
               END LOOP;
             END
             $$;"
        ))
        .await
        .context("failed to transfer AGE graph schema ownership")
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
    validate_stale_age(max_age_secs)?;
    let (admin, _task) = connect_admin(None).await?;

    // pg_database has no creation timestamp, so age comes from each database directory's
    // PG_VERSION marker. The OID-derived path is per database; using a pg_database relation path
    // here would age the shared catalog file and classify every disposable database identically.
    let rows = admin
        .query(
            STALE_DATABASE_QUERY,
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

        match admin.batch_execute(&stale_drop_statement(&name)).await {
            Ok(()) => dropped.push(name),
            // A database another run is actively using is not this sweep's problem.
            Err(err) => eprintln!("could not drop stale database {name}: {err}"),
        }
    }

    Ok(dropped)
}

fn stale_drop_statement(database: &str) -> String {
    format!("DROP DATABASE IF EXISTS {};", quote_ident(database))
}

fn validate_stale_age(max_age_secs: i64) -> Result<()> {
    if max_age_secs <= 0 {
        bail!("stale database age must be greater than zero seconds");
    }
    Ok(())
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
    fn stale_database_query_ages_each_candidate_directory() {
        assert!(STALE_DATABASE_QUERY.contains("format('base/%s/PG_VERSION', d.oid), true"));
        assert!(STALE_DATABASE_QUERY.contains("t.spcname = 'pg_default'"));
        assert!(!STALE_DATABASE_QUERY.contains("pg_relation_filepath('pg_database')"));
        assert!(!stale_drop_statement("sr_core_test_123_1").contains("WITH (FORCE)"));
    }

    #[test]
    fn stale_database_sweep_rejects_non_positive_age() {
        assert!(validate_stale_age(86_400).is_ok());
        assert!(validate_stale_age(0).is_err());
        assert!(validate_stale_age(-1).is_err());
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

    #[test]
    fn redacted_database_url_hides_userinfo_and_query_credentials() {
        assert_eq!(
            redacted_database_url(
                "postgres://app:userinfo-secret@fixture.example:5432/db?\
                 password=query-secret&sslmode=verify-full"
            ),
            "postgres://***@fixture.example:5432/db"
        );
        assert_eq!(
            redacted_database_url("postgres://fixture.example/db?password=query-secret"),
            "postgres://fixture.example/db"
        );
    }

    #[test]
    fn owner_comes_from_the_dsn_user_not_a_hardcoded_name() {
        // The regression this guards: a fixture whose application role is not called
        // "serviceradar" got `CREATE DATABASE ... OWNER serviceradar` and failed with
        // `role "serviceradar" does not exist`.
        assert_eq!(
            owner_from_url("postgres://srql_test:pw@host:5432/db?sslmode=require").unwrap(),
            "srql_test"
        );
        assert_eq!(
            owner_from_url("postgres://serviceradar@127.0.0.1:55433/postgres").unwrap(),
            "serviceradar"
        );
    }

    #[test]
    fn verified_libpq_ssl_modes_parse_for_the_rust_lifecycle() {
        for mode in ["verify-ca", "verify-full", "VERIFY-FULL"] {
            let config = parse_pg_config(
                &format!(
                    "postgres://srql_test:p%40ss@192.0.2.10:30818/srql_fixture?\
                     application_name=integration&sslmode={mode}"
                ),
                "SRQL_TEST_DATABASE_URL",
            )
            .unwrap();

            assert_eq!(config.get_user(), Some("srql_test"));
            assert_eq!(config.get_dbname(), Some("srql_fixture"));
            assert_eq!(config.get_application_name(), Some("integration"));
        }
    }

    #[test]
    fn sslmode_normalization_leaves_other_modes_and_parameters_unchanged() {
        let require = "postgres://u:p@host/db?sslmode=require&application_name=fixture";
        let disable = "postgres://u:p@host/db?sslmode=disable";

        assert!(matches!(
            normalize_sslmode_for_tokio_postgres(require),
            Cow::Borrowed(value) if value == require
        ));
        assert!(matches!(
            normalize_sslmode_for_tokio_postgres(disable),
            Cow::Borrowed(value) if value == disable
        ));
    }

    #[test]
    fn owner_from_url_requires_a_user() {
        // Silently defaulting is what produced a role name nothing had configured.
        assert!(owner_from_url("postgres://host:5432/db").is_err());
        assert!(owner_from_url("not a url").is_err());
    }

    #[test]
    fn verified_tls_accepts_only_verify_full() {
        for url in [
            "postgres://u:p@host:5432/db?sslmode=verify-full",
            "postgres://u:p@host:5432/db?application_name=x&sslmode=VERIFY-FULL",
        ] {
            assert!(require_verified_tls(url, "SRQL_TEST_DATABASE_URL").is_ok(), "{url}");
        }
    }

    #[test]
    fn verified_tls_rejects_a_dsn_that_permits_plaintext() {
        // No sslmode at all is the dangerous case: tokio-postgres defaults to Prefer, so the
        // connection succeeds in cleartext and nothing in the suite notices.
        for url in [
            "postgres://u:p@host:5432/db",
            "postgres://u:p@host:5432/db?application_name=x",
            "postgres://u:p@host:5432/db?sslmode=prefer",
            "postgres://u:p@host:5432/db?sslmode=require",
            "postgres://u:p@host:5432/db?sslmode=verify-ca",
            "postgres://u:p@host:5432/db?sslmode=disable",
        ] {
            assert!(require_verified_tls(url, "SRQL_TEST_DATABASE_URL").is_err(), "{url}");
        }
    }
}
