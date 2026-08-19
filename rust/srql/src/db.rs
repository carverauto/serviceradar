use crate::config::AppConfig;
use anyhow::{Context, Result};
use std::borrow::Cow;
use async_trait::async_trait;
use bb8::{ManageConnection, Pool};
use diesel_async::{AsyncPgConnection, SimpleAsyncConnection};
use std::time::Duration;
use tokio_postgres::{Config as PgConfig, NoTls};
use tracing::{error, info};

pub use crate::tls::PgRustlsConnect;

pub type PgPool = Pool<PgConnectionManager>;

/// Parses a PostgreSQL DSN for tokio-postgres, dropping `sslmode`.
///
/// The mode is not lost: TLS is configured from the typed posture and the connector is built
/// separately, so the string only has to describe the endpoint. tokio-postgres rejects the
/// verifying values outright, which is why this cannot be a bare `parse()`.
pub fn parse_pg_config(url: &str) -> Result<PgConfig> {
    strip_sslmode(url)
        .parse()
        .context("not a valid PostgreSQL connection string")
}

/// Removes any `sslmode` query parameter, preserving the rest of the DSN verbatim.
pub fn strip_sslmode(url: &str) -> Cow<'_, str> {
    let Some((base, query)) = url.split_once('?') else {
        return Cow::Borrowed(url);
    };

    let kept: Vec<&str> = query
        .split('&')
        .filter(|parameter| {
            !parameter
                .split_once('=')
                .is_some_and(|(key, _)| key.eq_ignore_ascii_case("sslmode"))
        })
        .collect();

    if kept.len() == query.split('&').count() {
        return Cow::Borrowed(url);
    }
    if kept.is_empty() {
        return Cow::Owned(base.to_string());
    }
    Cow::Owned(format!("{base}?{}", kept.join("&")))
}


pub async fn connect_pool(config: &AppConfig) -> Result<PgPool> {
    let manager = PgConnectionManager::new(
        &config.database_url,
        config.database_ca_pem.as_deref(),
        config.database_client_cert_pem.as_deref(),
        config.database_client_key_pem.as_deref(),
        config.database_tls_server_name.as_deref(),
        config.db_statement_timeout,
    )?;
    let pool = Pool::builder()
        .max_size(config.max_pool_size)
        .build(manager)
        .await
        .context("failed to build PostgreSQL connection pool")?;

    // Perform a one-time connectivity check so we fail fast if credentials are wrong.
    match pool.get().await {
        Ok(_) => info!("database connectivity check succeeded"),
        Err(err) => error!(error = ?err, "initial database connectivity check failed"),
    }

    Ok(pool)
}

#[derive(Clone)]
pub struct PgConnectionManager {
    config: PgConfig,
    tls: PgTls,
    statement_timeout: Duration,
}

#[derive(Clone)]
enum PgTls {
    None,
    Rustls(PgRustlsConnect),
}

impl PgConnectionManager {
    fn new(
        database_url: &str,
        ca_pem: Option<&[u8]>,
        client_cert_pem: Option<&[u8]>,
        client_key_pem: Option<&[u8]>,
        server_name: Option<&str>,
        statement_timeout: Duration,
    ) -> Result<Self> {
        // parse_pg_config, NOT a bare parse. config.rs builds this DSN with
        // `?sslmode=verify-full`, and tokio-postgres understands disable/prefer/require only --
        // so srql could not parse its own connection string in any verifying environment.
        let config = parse_pg_config(database_url).context("invalid DATABASE_URL")?;
        // Content all the way down. config.rs resolves the PEMs through SecretManager, so there
        // is no path to read and nothing that only exists on one host.
        let tls = match ca_pem {
            Some(ca) => PgTls::Rustls(crate::tls::postgres_connector(
                ca,
                client_cert_pem,
                client_key_pem,
                server_name,
            )?),
            None => PgTls::None,
        };
        Ok(Self {
            config,
            tls,
            statement_timeout,
        })
    }
}

#[async_trait]
impl ManageConnection for PgConnectionManager {
    type Connection = AsyncPgConnection;
    type Error = anyhow::Error;

    async fn connect(&self) -> Result<Self::Connection, Self::Error> {
        let config = self.config.clone();
        let mut conn = match &self.tls {
            PgTls::None => {
                let (client, connection) = config.connect(NoTls).await?;
                AsyncPgConnection::try_from_client_and_connection(client, connection)
                    .await
                    .map_err(|err| anyhow::anyhow!(err))
            }
            PgTls::Rustls(connector) => {
                let (client, connection) = config.connect(connector.clone()).await?;
                AsyncPgConnection::try_from_client_and_connection(client, connection)
                    .await
                    .map_err(|err| anyhow::anyhow!(err))
            }
        }?;

        apply_statement_timeout(&mut conn, self.statement_timeout).await?;
        Ok(conn)
    }

    async fn is_valid(&self, conn: &mut Self::Connection) -> Result<(), Self::Error> {
        conn.batch_execute("SELECT 1").await?;
        Ok(())
    }

    fn has_broken(&self, _: &mut Self::Connection) -> bool {
        false
    }
}

async fn apply_statement_timeout(conn: &mut AsyncPgConnection, timeout: Duration) -> Result<()> {
    let timeout_ms = timeout.as_millis().max(1);
    conn.batch_execute(&format!("SET statement_timeout = {timeout_ms}"))
        .await
        .context("failed to set SRQL PostgreSQL statement_timeout")?;
    Ok(())
}

#[cfg(test)]
mod parse_pg_config_tests {
    use super::*;

    /// config.rs assembles exactly this shape for a VERIFY_FULL environment. A bare
    /// `parse::<PgConfig>()` rejects it, which meant srql could not open its own pool.
    #[test]
    fn verifying_sslmode_is_accepted() {
        let config = parse_pg_config("postgres://srql:pw@db.example:5432/serviceradar?sslmode=verify-full")
            .expect("srql must parse the DSN it builds");
        assert_eq!(config.get_dbname(), Some("serviceradar"));
        assert_eq!(config.get_user(), Some("srql"));
    }

    #[test]
    fn other_parameters_survive_and_plain_dsns_are_untouched() {
        assert_eq!(
            strip_sslmode("postgres://h/db?sslmode=require&application_name=srql"),
            "postgres://h/db?application_name=srql"
        );
        assert_eq!(strip_sslmode("postgres://h/db"), "postgres://h/db");
    }
}
