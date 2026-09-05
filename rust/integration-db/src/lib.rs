/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Database lifecycle for the `serviceradar_core` integration suite.
//!
//! Replaces `scripts/reset-test-db.sh`, `scripts/drop-test-db.sh` and
//! `scripts/sweep-stale-core-test-dbs.sh`, so BuildBuddy (`buildbuddy.yaml`)
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
//! The name is read, never passed between steps. Provision, teardown and the suite each read
//! the same declared build input -- the file `//build:run_id_file` writes from
//! `--//build:run_id` -- so there is no handoff through a temp file or `GITHUB_ENV`, and no
//! ordering assumption about who wrote it first. The old shell embedded `date +%s`, which is
//! exactly the kind of value a later step cannot recompute.
//!
//! The id is a build flag rather than an environment variable so that no step reads ambient
//! process state to learn which database it owns, and so the value cannot differ between two
//! invocations of one run. Only actions that consume the file are invalidated when it changes;
//! `//build/run_id.bzl` explains why that does not reach any compile.

use std::fs;

pub mod config;
pub mod connection_observer;

use anyhow::{bail, Context, Result};
use srql::db::PgRustlsConnect;
use tokio::task::JoinHandle;
use tokio_postgres::{Client, Config as PgConfig, NoTls};

pub mod generation;
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

/// Where //build:run_id_file lands in runfiles. A declared input of every lifecycle target.
const RUN_ID_RUNFILE: &str = "build/run_id_file.txt";

/// Where //build:template_authority_file lands in runfiles. A declared input of every target
/// that WRITES the shared template.
///
/// Same contract as the run id, for the same reason: the trunk lifecycle is several separate
/// Bazel invocations sharing no process, and its Rust and Elixir halves must reach the same
/// answer about whether they may touch `sr_core_template`. Ambient environment would let one
/// step's answer differ from another's; a declared input cannot.
const TEMPLATE_AUTHORITY_RUNFILE: &str = "build/template_authority_file.txt";

/// The only content that grants shared-template write access. See //build/template_authority.bzl.
const TEMPLATE_AUTHORITY_MARKER: &str = "trunk";

/// Collisions only matter between runs that are live at the same time, and the sweep drops
/// the rest, so eight hex characters over a handful of concurrent runs is ample. A full
/// dash-stripped UUID still fits: 13-byte prefix + 32 + a shard suffix stays under 63.
const MIN_RUN_ID_BYTES: usize = 8;
const MAX_RUN_ID_BYTES: usize = 32;

/// What a step says when the run id was never passed.
///
/// It names the flag, says why there is no default, and gives the whole sequence, because the
/// failure surfaces in ONE of six invocations and the fix belongs to all of them.
const MISSING_RUN_ID: &str = "\
--//build:run_id is not set, so there is no database name to operate on.

Every step of the integration lifecycle derives its disposable database from this one value.
It has no default ON PURPOSE: a constant fallback name lets two runs against the same fixture
share a database, and each teardown then drops the other's data.

Mint one id and pass it to EVERY invocation of the sequence:

    RUN_ID=$(uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-8)

    bazel ... --//build:run_id=$RUN_ID //rust/integration-db:sweep_stale_dbs
    bazel ... --//build:run_id=$RUN_ID //rust/integration-db:provision_base
    bazel ... --//build:run_id=$RUN_ID //elixir/serviceradar_core:migrate_run
    bazel ... --//build:run_id=$RUN_ID //rust/integration-db:provision_db
    bazel ... --//build:run_id=$RUN_ID //elixir/serviceradar_core:integration_tests
    bazel ... --//build:run_id=$RUN_ID //rust/integration-db:teardown_db";

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

/// Names the shared fixture itself plus Postgres templates. The sweep will
/// drop any other database older than the cutoff: cancelled CI clones are
/// `sr_core_test_*`, but workstation leftovers use other prefixes and used to
/// accumulate until Timescale workers exhausted the instance.
const PROTECTED_DATABASES: &[&str] = &[
    "postgres",
    "template0",
    "template1",
    "srql_fixture",
    "sr_core_template",
];

/// Find disposable databases whose own data-directory marker is older than the cutoff.
///
/// Every integration clone uses pg_default. Restricting the query to that tablespace is safer
/// than guessing PostgreSQL's versioned external-tablespace path. Most importantly, the path is
/// derived from each candidate database's OID, and PG_VERSION is written when CREATE DATABASE
/// creates that directory but is not touched by ordinary relation activity.
/// `pg_relation_filepath('pg_database')` names one shared catalog file and therefore gives every
/// database the same all-or-none age.
#[allow(dead_code)] // retained so the prefix-specific age test still compiles
const STALE_DATABASE_QUERY: &str = "SELECT d.datname \
     FROM pg_database AS d \
     JOIN pg_tablespace AS t ON t.oid = d.dattablespace \
     WHERE d.datname LIKE $1 \
       AND t.spcname = 'pg_default' \
       AND (pg_stat_file(format('base/%s/PG_VERSION', d.oid), true)).modification \
           < now() - make_interval(secs => $2::double precision)";

/// Same age rule as [`STALE_DATABASE_QUERY`], but for every database that is
/// not the shared fixture. Keep the NOT IN list identical to
/// [`PROTECTED_DATABASES`] / `go/pkg/srqlfixture/reaper`.
const UNPROTECTED_STALE_QUERY: &str = "SELECT d.datname \
     FROM pg_database AS d \
     JOIN pg_tablespace AS t ON t.oid = d.dattablespace \
     WHERE NOT d.datistemplate \
       AND d.datname NOT IN ('postgres', 'template0', 'template1', 'srql_fixture', 'sr_core_template') \
       AND left(d.datname, 7) <> 'sr_tpl_' \
       AND t.spcname = 'pg_default' \
       AND (pg_stat_file(format('base/%s/PG_VERSION', d.oid), true)).modification \
           < now() - make_interval(secs => $1::double precision)";

/// The per-run database name, read from a declared build input.
///
/// The lifecycle is six separate Bazel invocations that share no process, so each must arrive
/// at the SAME name independently while two overlapping runs must not. That is a run
/// correlation id, and it can only come from outside the build: the caller mints one and
/// repeats `--//build:run_id=<id>` on every invocation. It reaches this crate as a file in
/// runfiles rather than as ambient environment, so the name a step operates on is something
/// the build graph declared.
///
/// There is deliberately no fallback. The previous code derived the name from `GITHUB_RUN_ID`
/// and fell back to one CONSTANT when it was absent, so two concurrent runs against a shared
/// fixture silently used the same database and each teardown dropped the other's data.
pub fn database_name() -> Result<String> {
    let path = config::runfile(RUN_ID_RUNFILE)?;
    let staged = fs::read_to_string(&path)
        .with_context(|| format!("reading the run id staged at {}", path.display()))?;

    validated_run_database_name(staged.trim())
}

/// The pure half of [`database_name`]: everything that can be wrong about a staged name.
///
/// Split from the runfiles read so these guards are unit-testable. They are the whole distance
/// between a malformed flag and a `DROP DATABASE` outside the disposable namespace, which is
/// not a thing to leave exercised only by a live run against a shared fixture.
fn validated_run_database_name(staged: &str) -> Result<String> {
    if staged.is_empty() {
        bail!("{}", MISSING_RUN_ID);
    }

    // //build/run_id.bzl writes the prefix; this checks it independently. The two can drift,
    // and this guard makes that fail loudly rather than pointing the run -- and every
    // `DROP DATABASE` in this crate -- at a name outside the disposable namespace.
    let Some(id) = staged.strip_prefix(DISPOSABLE_PREFIX) else {
        bail!("run id file holds {staged:?}, which does not start with {DISPOSABLE_PREFIX:?}");
    };

    if !(MIN_RUN_ID_BYTES..=MAX_RUN_ID_BYTES).contains(&id.len())
        || !id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    {
        bail!(
            "--//build:run_id must be {MIN_RUN_ID_BYTES}..={MAX_RUN_ID_BYTES} characters of \
             [a-z0-9], got {id:?} -- mint one with \
             `uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-{MIN_RUN_ID_BYTES}`"
        );
    }

    // The heavy bootstrap qualification owns sr_core_test_bootstrap_<random> scratch databases.
    // teardown_run also drops every <base>_% database, so accepting the exact base
    // sr_core_test_bootstrap would let one manual lifecycle delete another run's scratch DB.
    if id == "bootstrap" {
        bail!(
            "--//build:run_id value {id:?} is reserved for heavy bootstrap scratch databases; \
             mint a unique run id with \
             `uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-{MIN_RUN_ID_BYTES}`"
        );
    }

    Ok(staged.to_string())
}

// The identifier bound is structural rather than checked at runtime: the prefix plus the
// longest accepted id must leave room for a shard suffix inside PostgreSQL's limit. Moving
// either constant fails the BUILD instead of silently truncating a database name -- and a
// truncated name is two runs colliding on one database.
const _: () = assert!(DISPOSABLE_PREFIX.len() + MAX_RUN_ID_BYTES + 8 <= MAX_IDENTIFIER_BYTES);

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

/// Refuses to continue unless this checkout may write the shared template database.
///
/// The caller declares it with `--//build:template_authority=true`, which means "this checkout
/// is trunk". `sr_core_template` is cloned by every run and only ever ratchets forward, so
/// whoever advances it decides the schema every other branch gets -- and a branch that never
/// lands leaves migrations in it that exist nowhere else, which is what wedged every open pull
/// request on 2026-09-04.
///
/// //buildbuddy.yaml already names these targets only from the push-to-`staging` action, and
/// that placement is the fix. This is what makes it hold: placement is a convention a later
/// edit undoes silently, and one a workstation never obeyed at all -- the lifecycle is
/// documented as runnable by hand against the same shared CNPG fixture CI uses.
///
/// It REFUSES rather than quietly redirecting to the per-run base. A caller that reached for a
/// target named after the template meant the template, and silently doing something else is
/// how a run comes to report success for work it did not do.
pub fn require_template_authority(target: &str) -> Result<()> {
    if is_template_authority() {
        return Ok(());
    }

    bail!(
        "{target} writes the SHARED template {}, which only a trunk checkout may do; pass \
         --//build:template_authority=true if this checkout IS trunk. A branch applies its own \
         migrations to its own run base instead: //rust/integration-db:provision_base, then \
         //elixir/serviceradar_core:migrate_run.",
        template::TEMPLATE_DATABASE
    )
}

/// Whether this checkout may write the shared template database.
///
/// Read from a declared build input rather than the environment, for the same reason the run id
/// is: several invocations must agree, and ambient state lets them differ.
///
/// Fails CLOSED. Anything other than the exact marker -- an absent file, an empty one, a mangled
/// one -- reads as "not the authority". That direction costs a loud refusal the caller can act
/// on; the other poisons a fixture every open pull request clones.
fn is_template_authority() -> bool {
    // Infallible on purpose: every way of not finding the marker -- an undeclared input, an
    // unreadable file, wrong content -- is the SAME answer, "not the authority". Returning a
    // Result here would invite a caller to distinguish cases that must not be distinguished,
    // and a `?` on the lookup would turn a conservative default into a hard failure.
    let Ok(path) = config::runfile(TEMPLATE_AUTHORITY_RUNFILE) else {
        return false;
    };

    let Ok(staged) = fs::read_to_string(&path) else {
        return false;
    };

    is_authority_marker(&staged)
}

/// The pure half of [`is_template_authority`], so the fail-closed rule is unit-testable.
fn is_authority_marker(staged: &str) -> bool {
    staged.trim() == TEMPLATE_AUTHORITY_MARKER
}

/// The URL the Elixir suite connects with: the fixture URL, repointed at [`database_name`].
///
/// Everything except the path is preserved, so query parameters such as `sslmode` survive.
pub fn database_url() -> Result<String> {
    let fixture = config::Fixture::from_env()?;
    let name = database_name()?;
    Ok(fixture.database_url(&name)?.expose().to_string())
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

/// Refuse to touch anything that is not a per-run database.
pub fn assert_disposable(database: &str) -> Result<()> {
    if !database.starts_with(DISPOSABLE_PREFIX) {
        bail!("refusing to operate on {database:?}: expected a {DISPOSABLE_PREFIX}* database");
    }
    Ok(())
}

/// The role that owns the template database and every clone taken from it.
///
/// Resolved from `database.owning_role` in the declared environment, alongside the application
/// role that runs the suite. There is no per-setting environment override: provisioning and test
/// connections therefore cannot silently disagree about the owner of a disposable clone.
pub fn database_owner() -> Result<String> {
    Ok(config::Fixture::from_env()?.owning_role()?.to_string())
}

/// The admin URL, which must have rights to CREATE/DROP DATABASE and install extensions.
pub fn admin_url() -> Result<String> {
    let fixture = config::Fixture::from_env()?;
    let database = fixture.admin_database()?.to_string();
    Ok(fixture.admin_url_for(&database)?.expose().to_string())
}

/// Connect with the admin credentials, optionally overriding the database.
///
/// The returned [`JoinHandle`] drives the connection. Dropping the handle detaches
/// the task; abort it to close immediately when cancelling a multi-connection operation.
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
pub fn parse_pg_config(url: &str, variable: &str) -> Result<PgConfig> {
    // No sslmode rewriting. The DSN this crate builds carries `sslmode=verify-full`, which
    // tokio-postgres does not parse -- it understands disable/prefer/require only. Rather than
    // translate the string down to `require` and re-establish verification elsewhere, the mode is
    // read from the typed field and configures the connector directly; see tls_connector_for.
    srql::db::parse_pg_config(url)
        .with_context(|| format!("{variable} is not a valid PostgreSQL connection string"))
}

/// Removes `sslmode` from a DSN's query string.
///
/// The parameter is meaningful to libpq and to this crate's own assembly, but tokio-postgres
/// rejects the verifying values outright, and leaving it in would make the parse fail on a DSN
/// that is otherwise correct.
pub use srql::db::strip_sslmode;

async fn connect(config: PgConfig) -> Result<(Client, JoinHandle<()>)> {
    let fixture = config::Fixture::from_env()?;
    // Built BEFORE the attempt, because the failure has to name what was attempted.
    // tokio-postgres reports "error connecting to server" and nothing else -- not the host, not
    // the role, not whether TLS was even involved -- so a DNS failure, a firewall, a wrong role
    // and an unreachable port all read identically. That cost a CI cycle: `Name or service not
    // known` was the whole diagnostic, and which name went unsaid.
    let target = endpoint(&config, &fixture);

    match tls_connector_for(&fixture)? {
        Some(connector) => {
            let (client, connection) = config
                .connect(connector)
                .await
                .with_context(|| format!("connect to {target}"))?;
            Ok((client, spawn_connection(connection)))
        }
        None => {
            let (client, connection) = config
                .connect(NoTls)
                .await
                .with_context(|| format!("connect to {target}"))?;
            Ok((client, spawn_connection(connection)))
        }
    }
}

/// What a connection was aimed at, for an error message.
///
/// Assembled field by field on purpose. `PgConfig`'s own `Debug` renders the password, so
/// formatting the config -- the obvious shortcut -- would put a live credential in a build log
/// the moment a connection failed.
fn endpoint(config: &PgConfig, fixture: &config::Fixture) -> String {
    let port = config.get_ports().first().copied().unwrap_or(5432);
    let hosts = config
        .get_hosts()
        .iter()
        .map(|host| match host {
            tokio_postgres::config::Host::Tcp(name) => format!("{name}:{port}"),
            other => format!("{other:?}"),
        })
        .collect::<Vec<_>>()
        .join(", ");

    let role = config.get_user().unwrap_or("<no role>");
    let database = config.get_dbname().unwrap_or("<no database>");

    // The TLS posture is what separates "the server refused us" from "we refused the server",
    // and the CA is fetched over the network too -- so name the bundle when one is configured.
    let tls = match fixture.tls_mode() {
        Ok(mode) => {
            let name = fixture.tls_server_name().unwrap_or("<host>");
            format!("{} verifying {name}", mode.as_str_name())
        }
        Err(e) => format!("<unreadable tls_mode: {e}>"),
    };
    let ca = fixture.ca_bundle_url().unwrap_or("<none>");

    format!("{hosts} as {role}, database {database}, tls {tls}, ca bundle {ca}")
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
fn tls_connector_for(fixture: &config::Fixture) -> Result<Option<PgRustlsConnect>> {
    // The typed mode decides, not a substring of a query string. `require_verified_tls` used to
    // assert that by scanning the DSN, which held only for callers whose DSN came through the
    // credential pipeline that rewrote it; a DSN from a secret store bypassed the check entirely.
    let verifies = matches!(
        fixture.tls_mode()?,
        serviceradar_config_schema::TlsMode::VerifyCa
            | serviceradar_config_schema::TlsMode::VerifyFull
    );
    if !verifies {
        return Ok(None);
    }

    let Some(pem) = fixture.ca_pem()? else {
        return Ok(None);
    };

    // Building the connector is `srql::tls`, shared with the SRQL service. Two implementations
    // of one security decision drift, and these two already had: this one refused client
    // certificates outright while srql's read its CA from a file path.
    Ok(Some(srql::tls::postgres_connector(
        &pem,
        None,
        None,
        fixture.tls_server_name(),
    )?))
}

struct AbortConnectionOnDrop(JoinHandle<()>);

impl Drop for AbortConnectionOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub(crate) async fn install_extensions(database: &str, owner: &str) -> Result<()> {
    let (client, task) = connect_admin(Some(database)).await?;
    // In keyed preparation this future is cancelled if its ownership session dies.
    // Do not detach a separate initializer connection when that happens.
    let _driver = AbortConnectionOnDrop(task);

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

/// Drop leftover fixture databases older than `max_age_secs`.
///
/// Equivalent to `scripts/sweep-stale-core-test-dbs.sh`, plus workstation /
/// bootstrap leftovers that job never named. Runs that are cancelled or whose
/// runner dies never reach teardown, so without this the fixture accumulates
/// databases. Returns the names dropped.
///
/// Does not FORCE the drop: a database another run is still connected to is
/// left for that run. The in-cluster reaper (`k8s/srql-fixtures/scratch-reaper.yaml`)
/// is what FORCE-drops leftovers whose only remaining backends are Timescale
/// workers.
pub async fn sweep_stale(max_age_secs: i64) -> Result<Vec<String>> {
    validate_stale_age(max_age_secs)?;
    let (admin, _task) = connect_admin(None).await?;

    // pg_database has no creation timestamp, so age comes from each database directory's
    // PG_VERSION marker. The OID-derived path is per database; using a pg_database relation path
    // here would age the shared catalog file and classify every disposable database identically.
    let rows = admin
        .query(UNPROTECTED_STALE_QUERY, &[&(max_age_secs as f64)])
        .await
        .context("failed to list stale databases")?;

    let mut dropped = Vec::new();
    for row in rows {
        let name: String = row.get(0);

        // Belt and braces: the SQL already excludes these, but the guard is what
        // makes a mistake in the query non-destructive.
        if is_protected_database(&name) {
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

fn is_protected_database(name: &str) -> bool {
    PROTECTED_DATABASES.contains(&name) || name.starts_with("sr_tpl_")
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
    fn unprotected_stale_query_excludes_the_shared_fixture() {
        for name in PROTECTED_DATABASES {
            assert!(
                UNPROTECTED_STALE_QUERY.contains(&format!("'{name}'")),
                "unprotected sweep SQL must name {name}"
            );
        }
        assert!(UNPROTECTED_STALE_QUERY.contains("format('base/%s/PG_VERSION', d.oid), true"));
        assert!(is_protected_database("postgres"));
        assert!(is_protected_database("srql_fixture"));
        assert!(is_protected_database("sr_core_template"));
        assert!(is_protected_database("sr_tpl_0123456789abcdef"));
        assert!(is_protected_database("sr_tpl_build_42"));
        assert!(UNPROTECTED_STALE_QUERY.contains("left(d.datname, 7) <> 'sr_tpl_'"));
        assert!(!is_protected_database("codex_mfreeman_1"));
        assert!(!is_protected_database("sr_core_test_a1b2c3d4"));
    }

    #[test]
    fn template_write_authority_fails_closed() {
        // The safe direction is "not the authority": the write is refused and the shared
        // template is left exactly as it was found. The unsafe direction ratchets a database
        // every open pull request clones, which is the failure this mechanism exists to
        // prevent -- so only the exact marker grants it, and everything else is a refusal.
        assert!(is_authority_marker("trunk"));
        assert!(is_authority_marker("trunk\n"));
        assert!(is_authority_marker("  trunk  "));

        // The empty file an unset flag writes, and every plausible near-miss.
        assert!(!is_authority_marker(""));
        assert!(!is_authority_marker("\n"));
        assert!(!is_authority_marker("true"));
        assert!(!is_authority_marker("1"));
        assert!(!is_authority_marker("TRUNK"));
        assert!(!is_authority_marker("staging"));
        assert!(!is_authority_marker("trunk trunk"));
    }

    #[test]
    fn the_authority_marker_is_where_the_write_targets_look_for_it() {
        // The dangerous failure of a fail-closed gate is that it fails closed on the ONE caller
        // it is supposed to admit: a wrong runfile path or a renamed target would make
        // `is_template_authority` return false even on trunk, and the trunk lifecycle would
        // refuse itself -- with an error indistinguishable from a branch being correctly
        // stopped, since both are "not the authority".
        //
        // So resolve it here, from a target that declares the same input the write targets do.
        // The VALUE is not asserted: it follows from --//build:template_authority, which this
        // test must not care about. What is asserted is that the file is found, is readable, and
        // holds one of exactly two things.
        let path = config::runfile(TEMPLATE_AUTHORITY_RUNFILE)
            .expect("//build:template_authority_file is declared in this target's data");
        let staged = fs::read_to_string(&path).expect("the staged marker must be readable");

        assert!(
            staged.trim().is_empty() || is_authority_marker(&staged),
            "//build/template_authority.bzl writes the marker or nothing, got {staged:?}"
        );
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

        // The srql harness reset `database.database` -- the fixture concurrent branches share --
        // without consulting this guard. It now calls it, so this name must stay rejected.
        assert!(assert_disposable("srql_fixture").is_err());
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

    /// The DSN shape ConfigManager emits has to survive tokio-postgres, which is exactly where
    /// the previous one died -- before the TLS connector was ever reached.
    ///
    /// `tls_server_name` used to be appended as libpq's `&sslsni=1&host=<name>`. tokio-postgres
    /// has no `sslsni` arm, so it rejected the whole connection string; and it reads a
    /// query-string `host` as an ADDITIONAL host to dial, so even without the `sslsni` half the
    /// verification name would have become a silent second endpoint.
    #[test]
    fn the_config_manager_dsn_parses_where_the_libpq_shape_did_not() {
        const BASE: &str =
            "postgres://srql_test:p%40ss@192.0.2.10:30818/srql_fixture?sslmode=verify-full";

        let parsed = parse_pg_config(BASE, "SRQL_TEST_ADMIN_URL").expect("current shape parses");
        assert_eq!(parsed.get_dbname(), Some("srql_fixture"));

        let libpq = format!("{BASE}&sslsni=1&host=srql-fixture-local");
        let error = parse_pg_config(&libpq, "SRQL_TEST_ADMIN_URL")
            .expect_err("the libpq shape must not silently work");
        let chain = format!("{error:#}");
        assert!(
            chain.contains("sslsni"),
            "must name the rejected option: {chain}"
        );
    }

    /// A well-formed staged name survives unchanged.
    #[test]
    fn validated_run_database_name_accepts_a_well_formed_name() {
        let name = validated_run_database_name("sr_core_test_a1b2c3d4").unwrap();
        assert_eq!(name, "sr_core_test_a1b2c3d4");
    }

    #[test]
    fn validated_run_database_name_rejects_the_bootstrap_scratch_prefix() {
        let error = validated_run_database_name("sr_core_test_bootstrap")
            .unwrap_err()
            .to_string();

        assert!(
            error.contains("bootstrap"),
            "must name the reserved id: {error}"
        );
        assert!(
            error.contains("reserved"),
            "must explain the rejection: {error}"
        );
    }

    /// The unset flag writes an EMPTY file rather than failing at analysis, so this is the
    /// message a developer actually sees. It has to name the flag and say there is no default,
    /// because the old code silently substituted one constant name for every run.
    #[test]
    fn validated_run_database_name_rejects_an_unset_flag_with_actionable_guidance() {
        let error = validated_run_database_name("").unwrap_err().to_string();

        assert!(
            error.contains("--//build:run_id"),
            "must name the flag: {error}"
        );
        assert!(
            error.contains("no default"),
            "must say there is no default: {error}"
        );
        assert!(
            error.contains("uuidgen"),
            "must show how to mint one: {error}"
        );
        // The failure surfaces in one of six invocations but the fix belongs to all of them.
        for target in [
            "sweep_stale_dbs",
            "provision_base",
            "migrate_run",
            "provision_db",
            "integration_tests",
            "teardown_db",
        ] {
            assert!(error.contains(target), "must list {target}: {error}");
        }
    }

    /// The drift guard. //build/run_id.bzl writes the prefix and this checks it independently,
    /// so a mismatch must fail rather than aim teardown outside the disposable namespace.
    #[test]
    fn validated_run_database_name_rejects_a_name_outside_the_disposable_prefix() {
        assert!(validated_run_database_name("serviceradar").is_err());
        assert!(validated_run_database_name("sr_core_prod_a1b2c3d4").is_err());
        // The shared fixture itself is the name this must never let through.
        assert!(validated_run_database_name("postgres").is_err());
    }

    /// Both bounds are inclusive, checked at the boundary rather than near it.
    #[test]
    fn validated_run_database_name_accepts_the_exact_length_bounds() {
        let shortest = format!("{DISPOSABLE_PREFIX}{}", "a".repeat(MIN_RUN_ID_BYTES));
        let longest = format!("{DISPOSABLE_PREFIX}{}", "a".repeat(MAX_RUN_ID_BYTES));

        assert!(validated_run_database_name(&shortest).is_ok(), "{shortest}");
        assert!(validated_run_database_name(&longest).is_ok(), "{longest}");
    }

    #[test]
    fn validated_run_database_name_rejects_lengths_just_outside_the_bounds() {
        let too_short = format!("{DISPOSABLE_PREFIX}{}", "a".repeat(MIN_RUN_ID_BYTES - 1));
        let too_long = format!("{DISPOSABLE_PREFIX}{}", "a".repeat(MAX_RUN_ID_BYTES + 1));

        assert!(
            validated_run_database_name(&too_short).is_err(),
            "{too_short}"
        );
        assert!(
            validated_run_database_name(&too_long).is_err(),
            "{too_long}"
        );
    }

    /// `uuidgen` output is rejected until it has been stripped and lowercased, which is why the
    /// error carries the exact pipeline rather than just naming the character class. An
    /// unquoted dash or uppercase letter in an identifier is a different database, or a syntax
    /// error, depending on where it lands.
    #[test]
    fn validated_run_database_name_rejects_raw_uuidgen_output() {
        let raw = format!("{DISPOSABLE_PREFIX}A1B2C3D4-E5F6");
        let dashed = format!("{DISPOSABLE_PREFIX}a1b2-c3d4");
        let upper = format!("{DISPOSABLE_PREFIX}A1B2C3D4");

        for candidate in [&raw, &dashed, &upper] {
            assert!(
                validated_run_database_name(candidate).is_err(),
                "should reject {candidate}"
            );
        }
    }

    /// The whole point of the change: no name is derivable without the flag, so there is no
    /// constant two concurrent runs could both land on.
    #[test]
    fn no_run_database_name_exists_without_an_explicit_run_id() {
        assert!(validated_run_database_name("").is_err());
        assert!(validated_run_database_name(DISPOSABLE_PREFIX).is_err());
        assert!(validated_run_database_name("sr_core_test_local").is_err());
    }
}
