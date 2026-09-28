/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Prints one already-cloned `sr_core_test_<run>_<shard>` database's connection identity as JSON.
//!
//! `//rust/integration-db:provision_generation_<shard>` clones that database from the ready
//! schema generation; this binary does not provision anything itself, it only resolves and
//! reports the identity a NON-Rust, NON-Elixir caller needs to connect to that same database
//! directly. It exists because `//integration_tests/edge_record:vertical_slice_test`
//! (unify-sweep-results-proto task 0.12) spawns two real Elixir Mix RELEASES as OS subprocesses,
//! and a release reads plain `CNPG_*` environment variables from `runtime.exs` -- not the typed
//! `SERVICERADAR_ENV=ci` / `ConfigManager` identity every `mix test`-based integration lane
//! resolves internally. That typed identity is the only thing this repository actually trusts
//! for the CI Postgres fixture's host/port/role/TLS posture, so translating it into plain env
//! vars needs this binary's help rather than a second, hand-rolled resolution.
//!
//! The shard comes from `SERVICERADAR_TEST_DB_SHARD`, the same variable the Elixir lanes' BUILD
//! `env` sets to name their clone. Under the generation lifecycle `sr_core_test_<run>` itself is
//! only the generation LEASE id -- every database is a `_<shard>` clone of the generation -- so a
//! caller that connects to the unsuffixed name reaches a database that does not exist, and an
//! Ecto pool aimed at it reports every query as "connection not available".
//!
//! # Why a binary and not a test
//!
//! Same reason as the generation binaries: it reports on stdout for a caller to consume, and a
//! declared data dependency lets the consuming test execute it inside its own runfiles.
//!
//! # Why this prints a password
//!
//! The stdout of this binary is read once by the caller's own process and fed straight into the
//! environment of the subprocesses that SAME test starts -- it never crosses a log line, a
//! cache, or a second process boundary. Every other credential this crate handles (SecretManager
//! passwords, `Dsn`) is already treated this way at rest; this is the same trust boundary, one
//! hop further out because the consumer is a released application, not this crate itself.

use std::io::Write as _;

use anyhow::{Context, Result};
use base64::Engine as _;
use serde::Serialize;
use serviceradar_config_schema::TlsMode;
use serviceradar_integration_db::{self as db, config::Fixture};

#[derive(Serialize)]
struct ShardCnpgConfig {
    host: String,
    port: u16,
    database: String,
    username: String,
    password: String,
    sslmode: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    tls_server_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ca_pem_base64: Option<String>,
    // The CREATEDB/DDL-capable role, distinct from `username` above (which deliberately lacks
    // it -- see Fixture::admin_url_for). Task 0.12 Group D's forced-CNPG-rollback probe needs a
    // role that can transiently REVOKE/GRANT table privileges on the app role to make one
    // specific write fail closed; nothing else in this binary's output needs it.
    admin_username: String,
    admin_password: String,
}

fn main() -> Result<()> {
    let fixture = Fixture::from_env().context("resolve SERVICERADAR_ENV fixture identity")?;
    let shard = std::env::var("SERVICERADAR_TEST_DB_SHARD").context(
        "SERVICERADAR_TEST_DB_SHARD names the clone to describe; the consuming target's BUILD \
         `env` sets it",
    )?;
    let name = db::shard_database_name(&shard).context("resolve the shard database name")?;

    let dsn = fixture
        .database_url(&name)
        .context("build the shard's application DSN")?;
    let pg_config = db::parse_pg_config(dsn.expose(), "shard DSN")
        .context("parse the shard DSN into host/port/user/password/dbname")?;

    let host = pg_config
        .get_hosts()
        .first()
        .context("shard DSN names no host")?;
    let host = match host {
        tokio_postgres::config::Host::Tcp(h) => h.clone(),
        #[cfg(unix)]
        tokio_postgres::config::Host::Unix(p) => {
            anyhow::bail!("shard DSN resolved to a Unix socket path ({p:?}), not a TCP host")
        }
    };
    let port = *pg_config
        .get_ports()
        .first()
        .context("shard DSN names no port")?;
    let username = pg_config
        .get_user()
        .context("shard DSN names no user")?
        .to_string();
    let password = pg_config
        .get_password()
        .context("shard DSN carries no password")?;
    let password =
        String::from_utf8(password.to_vec()).context("shard DSN password is not valid UTF-8")?;
    let database = pg_config
        .get_dbname()
        .context("shard DSN names no database")?
        .to_string();

    let sslmode = match fixture.tls_mode().context("resolve database.tls_mode")? {
        TlsMode::Disable => "disable",
        TlsMode::Require => "require",
        TlsMode::VerifyCa => "verify-ca",
        TlsMode::VerifyFull => "verify-full",
        TlsMode::Unspecified => anyhow::bail!("database.tls_mode is unspecified"),
    };
    let tls_server_name = fixture.tls_server_name().map(str::to_string);
    let ca_pem_base64 = fixture
        .ca_pem()
        .context("resolve the fixture's CA PEM")?
        .map(|pem| base64::engine::general_purpose::STANDARD.encode(pem));

    let admin_dsn = fixture
        .admin_url_for(&database)
        .context("build the shard's admin DSN")?;
    let admin_pg_config = db::parse_pg_config(admin_dsn.expose(), "shard admin DSN")
        .context("parse the shard admin DSN into user/password")?;
    let admin_username = admin_pg_config
        .get_user()
        .context("shard admin DSN names no user")?
        .to_string();
    let admin_password = admin_pg_config
        .get_password()
        .context("shard admin DSN carries no password")?;
    let admin_password = String::from_utf8(admin_password.to_vec())
        .context("shard admin DSN password is not valid UTF-8")?;

    let out = ShardCnpgConfig {
        host,
        port,
        database,
        username,
        password,
        sslmode,
        tls_server_name,
        ca_pem_base64,
        admin_username,
        admin_password,
    };

    let json = serde_json::to_string(&out).context("serialize shard connection identity")?;
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{json}").context("write shard connection identity to stdout")?;
    stdout.flush().context("flush stdout")?;
    Ok(())
}
