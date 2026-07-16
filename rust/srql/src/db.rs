use crate::config::AppConfig;
use anyhow::{Context, Result};
use async_trait::async_trait;
use bb8::{ManageConnection, Pool};
use diesel_async::{AsyncPgConnection, SimpleAsyncConnection};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::certs;
use std::fs::File;
use std::io::BufReader;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_postgres::{Config as PgConfig, NoTls, tls::MakeTlsConnect};
use tokio_postgres_rustls::MakeRustlsConnect;
use tracing::{error, info};

pub type PgPool = Pool<PgConnectionManager>;

fn ensure_rustls_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

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

#[derive(Clone)]
pub struct PgRustlsConnect {
    inner: MakeRustlsConnect,
    server_name: Option<String>,
}

impl PgRustlsConnect {
    pub fn new(config: ClientConfig, server_name: Option<String>) -> Self {
        Self {
            inner: MakeRustlsConnect::new(config),
            server_name,
        }
    }
}

impl<S> MakeTlsConnect<S> for PgRustlsConnect
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    type Stream = <MakeRustlsConnect as MakeTlsConnect<S>>::Stream;
    type TlsConnect = <MakeRustlsConnect as MakeTlsConnect<S>>::TlsConnect;
    type Error = <MakeRustlsConnect as MakeTlsConnect<S>>::Error;

    fn make_tls_connect(&mut self, hostname: &str) -> Result<Self::TlsConnect, Self::Error> {
        let hostname = self.server_name.as_deref().unwrap_or(hostname);
        <MakeRustlsConnect as MakeTlsConnect<S>>::make_tls_connect(&mut self.inner, hostname)
    }
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
        let tls = if let Some(path) = root_cert {
            PgTls::Rustls(build_tls_connector(
                path,
                client_cert,
                client_key,
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

fn build_tls_connector(
    root_cert: &str,
    client_cert: Option<&str>,
    client_key: Option<&str>,
    server_name: Option<&str>,
) -> Result<PgRustlsConnect> {
    let mut reader = BufReader::new(File::open(root_cert).context("failed to open PGSSLROOTCERT")?);
    let mut root_store = RootCertStore::empty();
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse PGSSLROOTCERT")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow::anyhow!("invalid certificate in PGSSLROOTCERT"))?;
    }

    Ok(PgRustlsConnect::new(
        build_client_config(root_store, root_cert, client_cert, client_key)?,
        server_name.map(str::to_string),
    ))
}

fn build_client_config(
    root_store: RootCertStore,
    root_cert: &str,
    client_cert: Option<&str>,
    client_key: Option<&str>,
) -> Result<ClientConfig> {
    ensure_rustls_crypto_provider();
    let builder = ClientConfig::builder().with_root_certificates(root_store);

    match (client_cert, client_key) {
        (None, None) => Ok(builder.with_no_client_auth()),
        (Some(cert), Some(key)) => {
            let certs = load_client_certs(cert)?;
            let key = load_client_key(key)?;
            builder
                .with_client_auth_cert(certs, key)
                .with_context(|| format!("failed to build client TLS config for {root_cert}"))
        }
        _ => anyhow::bail!("PGSSLCERT and PGSSLKEY must both be set (or neither)"),
    }
}

fn load_client_certs(path: &str) -> Result<Vec<CertificateDer<'static>>> {
    let mut reader = BufReader::new(
        File::open(path).with_context(|| format!("failed to open PGSSLCERT file '{path}'"))?,
    );

    let mut chain = Vec::new();
    for cert in certs(&mut reader) {
        chain.push(cert.context("failed to parse PGSSLCERT")?);
    }

    if chain.is_empty() {
        anyhow::bail!("PGSSLCERT contained no certificates");
    }

    Ok(chain)
}

fn load_client_key(path: &str) -> Result<PrivateKeyDer<'static>> {
    let mut reader = BufReader::new(
        File::open(path).with_context(|| format!("failed to open PGSSLKEY file '{path}'"))?,
    );

    let key = rustls_pemfile::private_key(&mut reader)
        .context("failed to parse PGSSLKEY")?
        .context("PGSSLKEY contained no private keys")?;

    Ok(key)
}
