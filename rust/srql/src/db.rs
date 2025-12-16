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
use tokio_postgres::{Config as PgConfig, NoTls};
use tokio_postgres_rustls::MakeRustlsConnect;
use tracing::{error, info};

pub type PgPool = Pool<PgConnectionManager>;

pub async fn connect_pool(config: &AppConfig) -> Result<PgPool> {
    let manager = PgConnectionManager::new(
        &config.database_url,
        config.pg_ssl_root_cert.as_deref(),
        config.pg_ssl_cert.as_deref(),
        config.pg_ssl_key.as_deref(),
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
}

#[derive(Clone)]
enum PgTls {
    None,
    Rustls(MakeRustlsConnect),
}

impl PgConnectionManager {
    fn new(
        database_url: &str,
        root_cert: Option<&str>,
        client_cert: Option<&str>,
        client_key: Option<&str>,
    ) -> Result<Self> {
        let config = database_url
            .parse::<PgConfig>()
            .context("invalid DATABASE_URL")?;
        let tls = if let Some(path) = root_cert {
            PgTls::Rustls(build_tls_connector(path, client_cert, client_key)?)
        } else {
            PgTls::None
        };
        Ok(Self { config, tls })
    }
}

#[async_trait]
impl ManageConnection for PgConnectionManager {
    type Connection = AsyncPgConnection;
    type Error = anyhow::Error;

    async fn connect(&self) -> Result<Self::Connection, Self::Error> {
        let config = self.config.clone();
        match &self.tls {
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
        }
    }

    async fn is_valid(&self, conn: &mut Self::Connection) -> Result<(), Self::Error> {
        conn.batch_execute("SELECT 1").await?;
        Ok(())
    }

    fn has_broken(&self, _: &mut Self::Connection) -> bool {
        false
    }
}

fn build_tls_connector(
    root_cert: &str,
    client_cert: Option<&str>,
    client_key: Option<&str>,
) -> Result<MakeRustlsConnect> {
    let mut reader = BufReader::new(File::open(root_cert).context("failed to open PGSSLROOTCERT")?);
    let mut root_store = RootCertStore::empty();
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse PGSSLROOTCERT")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow::anyhow!("invalid certificate in PGSSLROOTCERT"))?;
    }

    Ok(MakeRustlsConnect::new(build_client_config(
        root_store,
        root_cert,
        client_cert,
        client_key,
    )?))
}

fn build_client_config(
    root_store: RootCertStore,
    root_cert: &str,
    client_cert: Option<&str>,
    client_key: Option<&str>,
) -> Result<ClientConfig> {
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
