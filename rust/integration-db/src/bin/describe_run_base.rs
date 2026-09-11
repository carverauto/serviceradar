/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Prints the already-provisioned run base's connection identity as JSON.
//!
//! `//rust/integration-db:provision_base` seeds and migrates `sr_core_test_<run>`; this binary
//! does not provision anything itself, it only resolves and reports the identity a NON-Rust,
//! NON-Elixir caller needs to connect to that same database directly. It exists because
//! `//integration_tests/edge_record:vertical_slice_test` (unify-sweep-results-proto task 0.12)
//! spawns two real Elixir Mix RELEASES as OS subprocesses, and a release reads plain `CNPG_*`
//! environment variables from `runtime.exs` -- not the typed `SERVICERADAR_ENV=ci` /
//! `ConfigManager` identity every `mix test`-based integration lane resolves internally. That
//! typed identity is the only thing this repository actually trusts for the CI Postgres
//! fixture's host/port/role/TLS posture, so translating it into plain env vars needs this
//! binary's help rather than a second, hand-rolled resolution.
//!
//! # Why a binary and not a test
//!
//! Same reason as `provision_base`: it reports on stdout for a caller to consume, and
//! `bazel run` launches it on the caller without a TestRunner placement strategy.
//!
//! # Why this prints a password
//!
//! The stdout of this binary is redirected straight to a file the caller reads once and then
//! feeds into `--test_env`/subprocess environment variables for the SAME CI job -- it never
//! crosses a log line, a cache, or a second process boundary. Every other credential this crate
//! handles (SecretManager passwords, `Dsn`) is already treated this way at rest; this is the
//! same trust boundary, one hop further out because the consumer is a released application, not
//! this crate itself.

use std::io::Write as _;

use anyhow::{Context, Result};
use base64::Engine as _;
use serde::Serialize;
use serviceradar_config_schema::TlsMode;
use serviceradar_integration_db::{self as db, config::Fixture};

#[derive(Serialize)]
struct RunBaseCnpgConfig {
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
    let name = db::database_name().context("resolve the run base database name")?;

    let dsn = fixture
        .database_url(&name)
        .context("build the run base's application DSN")?;
    let pg_config = db::parse_pg_config(dsn.expose(), "run base DSN")
        .context("parse the run base DSN into host/port/user/password/dbname")?;

    let host = pg_config
        .get_hosts()
        .first()
        .context("run base DSN names no host")?;
    let host = match host {
        tokio_postgres::config::Host::Tcp(h) => h.clone(),
        #[cfg(unix)]
        tokio_postgres::config::Host::Unix(p) => {
            anyhow::bail!("run base DSN resolved to a Unix socket path ({p:?}), not a TCP host")
        }
    };
    let port = *pg_config
        .get_ports()
        .first()
        .context("run base DSN names no port")?;
    let username = pg_config
        .get_user()
        .context("run base DSN names no user")?
        .to_string();
    let password = pg_config
        .get_password()
        .context("run base DSN carries no password")?;
    let password =
        String::from_utf8(password.to_vec()).context("run base DSN password is not valid UTF-8")?;
    let database = pg_config
        .get_dbname()
        .context("run base DSN names no database")?
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
        .context("build the run base's admin DSN")?;
    let admin_pg_config = db::parse_pg_config(admin_dsn.expose(), "run base admin DSN")
        .context("parse the run base admin DSN into user/password")?;
    let admin_username = admin_pg_config
        .get_user()
        .context("run base admin DSN names no user")?
        .to_string();
    let admin_password = admin_pg_config
        .get_password()
        .context("run base admin DSN carries no password")?;
    let admin_password = String::from_utf8(admin_password.to_vec())
        .context("run base admin DSN password is not valid UTF-8")?;

    let out = RunBaseCnpgConfig {
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

    let json = serde_json::to_string(&out).context("serialize run base connection identity")?;
    let mut stdout = std::io::stdout();
    stdout
        .write_all(json.as_bytes())
        .and_then(|_| stdout.write_all(b"\n"))
        .context("write run base connection identity to stdout")?;
    Ok(())
}
