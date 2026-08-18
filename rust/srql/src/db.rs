use crate::config::AppConfig;
use anyhow::{Context, Result};
use async_trait::async_trait;
use bb8::{ManageConnection, Pool};
use diesel_async::{AsyncPgConnection, SimpleAsyncConnection};
use std::time::Duration;
use tokio_postgres::{Config as PgConfig, NoTls};
use tracing::{error, info};

pub use crate::tls::PgRustlsConnect;

pub type PgPool = Pool<PgConnectionManager>;

pub async fn connect_pool(config: &AppConfig) -> Result<PgPool> {
    let manager = PgConnectionManager::new(
        &config.database_url,
        config.pg_ssl_root_cert.as_deref(),
        config.pg_ssl_cert.as_deref(),
        config.pg_ssl_key.as_deref(),
        config.pg_ssl_server_name.as_deref(),
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
        root_cert: Option<&str>,
        client_cert: Option<&str>,
        client_key: Option<&str>,
        server_name: Option<&str>,
        statement_timeout: Duration,
    ) -> Result<Self> {
        let config = database_url
            .parse::<PgConfig>()
            .context("invalid DATABASE_URL")?;
        // Read the PEM here: the shared builder takes CONTENT, because a path is only
        // meaningful on the host that resolves it. config.rs still yields paths; when it
        // resolves through SecretManager instead, this adapter goes and the content is passed
        // straight through.
        let tls = if let Some(path) = root_cert {
            let read = |p: &str| std::fs::read(p).with_context(|| format!("failed to read {p}"));
            let ca = read(path)?;
            let cert = client_cert.map(read).transpose()?;
            let key = client_key.map(read).transpose()?;
            PgTls::Rustls(crate::tls::postgres_connector(
                &ca,
                cert.as_deref(),
                key.as_deref(),
                server_name,
            )?)
        } else {
            PgTls::None
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




