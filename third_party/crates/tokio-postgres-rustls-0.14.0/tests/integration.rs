#![cfg(any(feature = "aws-lc-rs", feature = "ring"))]

use tokio_postgres::Config;
use tokio_postgres::config::{ChannelBinding, SslMode};
use tokio_postgres_rustls::MakeRustlsConnect;

mod support;

use support::certstore::CertStore;
use support::docker::PostgresContainer;

const SETUP_SCRIPT: &str = "tests/support/sql_setup.sh";
const CA_CERT: &str = "tests/support/ca.crt";
const SERVER_CERT: &str = "tests/support/server.crt";
const SERVER_SHA384_CERT: &str = "tests/support/server_sha384.crt";
const SERVER_SHA512_CERT: &str = "tests/support/server_sha512.crt";
const SERVER_KEY: &str = "tests/support/server.key";

#[tokio::test]
async fn ssl_user_without_client_cert_rejected() {
    let mut pg = start_postgres("ssl-user-without-client-cert-rejected", SERVER_CERT).await;

    let tls_config = client_config_builder()
        .with_root_certificates(CertStore::roots())
        .with_no_client_auth();
    let tls = MakeRustlsConnect::new(tls_config);

    let result = pg_config(pg.port, "ssl_user")
        .ssl_mode(SslMode::Prefer)
        .connect(tls)
        .await;
    let Err(err) = result else {
        pg.cleanup().await;
        panic!("connect to postgres as ssl_user without client auth should fail");
    };

    pg.cleanup().await;

    let db_error = err
        .as_db_error()
        .expect("client cert rejection should be a database error");
    assert_eq!(
        db_error.message(),
        "connection requires a valid client certificate"
    );
}

#[tokio::test]
async fn ssl_user_ok() {
    let mut pg = start_postgres("ssl-user-with-client-cert-ok", SERVER_CERT).await;
    let certs = CertStore::sha256();

    let tls_config = client_config_builder()
        .with_root_certificates(certs.roots)
        .with_client_auth_cert(certs.client_certs, certs.client_key)
        .expect("build rustls client config");
    let tls = MakeRustlsConnect::new(tls_config);

    assert_select_one(
        pg_config(pg.port, "ssl_user").ssl_mode(SslMode::Require),
        tls,
    )
    .await;
    pg.cleanup().await;
}

#[tokio::test]
async fn scram_sha256_channel_binding_works() {
    let mut pg = start_postgres("scram-sha256", SERVER_CERT).await;
    let certs = CertStore::sha256();

    let tls_config = client_config_builder()
        .with_root_certificates(certs.roots)
        .with_client_auth_cert(certs.client_certs, certs.client_key)
        .expect("build rustls client config");
    let tls = MakeRustlsConnect::new(tls_config);

    assert_select_one(&scram_config(pg.port), tls).await;
    pg.cleanup().await;
}

#[tokio::test]
async fn scram_sha384_channel_binding_works() {
    let mut pg = start_postgres("scram-sha384", SERVER_SHA384_CERT).await;
    let certs = CertStore::sha384();

    let tls_config = client_config_builder()
        .with_root_certificates(certs.roots)
        .with_client_auth_cert(certs.client_certs, certs.client_key)
        .expect("build rustls client config");
    let tls = MakeRustlsConnect::new(tls_config);

    assert_select_one(&scram_config(pg.port), tls).await;
    pg.cleanup().await;
}

#[tokio::test]
async fn scram_sha512_channel_binding_works() {
    let mut pg = start_postgres("scram-sha512", SERVER_SHA512_CERT).await;
    let certs = CertStore::sha512();

    let tls_config = client_config_builder()
        .with_root_certificates(certs.roots)
        .with_client_auth_cert(certs.client_certs, certs.client_key)
        .expect("build rustls client config");
    let tls = MakeRustlsConnect::new(tls_config);

    assert_select_one(&scram_config(pg.port), tls).await;
    pg.cleanup().await;
}

fn client_config_builder() -> rustls::ConfigBuilder<rustls::ClientConfig, rustls::WantsVerifier> {
    rustls::ClientConfig::builder_with_provider(provider().into())
        .with_safe_default_protocol_versions()
        .expect("default protocol versions")
}

#[cfg(feature = "aws-lc-rs")]
fn provider() -> rustls::crypto::CryptoProvider {
    rustls::crypto::aws_lc_rs::default_provider()
}

#[cfg(all(not(feature = "aws-lc-rs"), feature = "ring"))]
fn provider() -> rustls::crypto::CryptoProvider {
    rustls::crypto::ring::default_provider()
}

async fn start_postgres(test_name: &str, server_cert: &str) -> PostgresContainer {
    PostgresContainer::new(test_name, SETUP_SCRIPT, CA_CERT, server_cert, SERVER_KEY)
        .await
        .expect("start postgres test container")
}

fn pg_config(port: u16, user: &str) -> Config {
    let mut config = Config::new();
    config
        .host("localhost")
        .port(port)
        .dbname("postgres")
        .user(user);
    config
}

fn scram_config(port: u16) -> Config {
    let mut config = pg_config(port, "scram_user");
    config
        .password("password")
        .ssl_mode(SslMode::Require)
        .channel_binding(ChannelBinding::Require);
    config
}

async fn assert_select_one(config: &Config, tls: MakeRustlsConnect) {
    let (client, conn) = config.connect(tls).await.expect("connect");
    tokio::spawn(async move { conn.await.map_err(|e| panic!("{e:?}")) });

    let row = client
        .query_one("SELECT 1::INT4", &[])
        .await
        .expect("query");
    assert_eq!(row.get::<_, i32>(0), 1);
}
