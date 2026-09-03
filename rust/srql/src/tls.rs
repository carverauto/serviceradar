//! Building a PostgreSQL TLS connector, once.
//!
//! This existed twice: `build_tls_connector` here and `tls_connector_for` in
//! `//rust/integration-db`. Two implementations of a security decision drift, and these two
//! already had: one supported client certificates and read the CA from a FILE PATH, the other
//! took PEM content and refused client auth outright.
//!
//! Everything is PEM CONTENT, never a path. A path is only meaningful on the host that resolves
//! it, which is what tied a test action to one machine; and `SecretManager` yields content,
//! because a secret that must be a file on disk cannot be a Kubernetes secret, a Docker secret
//! and a developer's directory at the same time.
//!
//! What is NOT here: deciding whether TLS applies at all. That is `DatabaseConfig.tls_mode`, and
//! the caller reads it -- a connector builder that silently returns "no TLS" is how a verifying
//! posture becomes a plaintext connection.

use anyhow::{anyhow, Context, Result};
use rustls::pki_types::PrivateKeyDer;
use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::certs;
use std::io::{BufReader, Cursor};
use std::sync::Once;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_postgres::tls::MakeTlsConnect;
use tokio_postgres_rustls::MakeRustlsConnect;

/// `MakeRustlsConnect` with the verification name pinned.
///
/// tokio-postgres passes the DIALLED host to the TLS layer, so an address-based caller would
/// verify the certificate against an IP. Substituting the configured name here is what makes
/// `DatabaseConfig.tls_server_name` mean anything.
#[derive(Clone)]
pub struct PgRustlsConnect {
    inner: MakeRustlsConnect,
    server_name: Option<String>,
}

impl PgRustlsConnect {
    pub fn new(config: ClientConfig, server_name: Option<String>) -> Self {
        Self { inner: MakeRustlsConnect::new(config), server_name }
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

/// rustls installs a process-wide crypto provider, and doing it twice panics.
static CRYPTO_PROVIDER: Once = Once::new();

fn ensure_crypto_provider() {
    CRYPTO_PROVIDER.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

/// A connector that verifies the server against `ca_pem`.
///
/// `server_name` is the name verification is performed against, which is NOT necessarily the
/// address dialled: a certificate carrying DNS SANs and no IP SANs cannot be verified by an
/// address-based caller unless the name is stated. It reaches rustls here rather than travelling
/// in the DSN -- libpq's `sslsni=1&host=<name>` is rejected outright by tokio-postgres, and its
/// query-string `host` is read as an ADDITIONAL endpoint to dial.
pub fn postgres_connector(
    ca_pem: &[u8],
    client_cert_pem: Option<&[u8]>,
    client_key_pem: Option<&[u8]>,
    server_name: Option<&str>,
) -> Result<PgRustlsConnect> {
    ensure_crypto_provider();

    let mut root_store = RootCertStore::empty();
    let mut reader = BufReader::new(Cursor::new(ca_pem));
    let mut added = 0usize;
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse the CA certificate")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow!("invalid certificate in the CA bundle"))?;
        added += 1;
    }
    if added == 0 {
        // An empty root store verifies nothing, and rustls does not object -- every handshake
        // would simply fail later, far from the cause.
        anyhow::bail!("the CA bundle contained no certificates");
    }

    let builder = ClientConfig::builder().with_root_certificates(root_store);

    let config = match (client_cert_pem, client_key_pem) {
        (None, None) => builder.with_no_client_auth(),
        (Some(cert_pem), Some(key_pem)) => {
            let chain = certs(&mut BufReader::new(Cursor::new(cert_pem)))
                .collect::<Result<Vec<_>, _>>()
                .context("failed to parse the client certificate")?;
            if chain.is_empty() {
                anyhow::bail!("the client certificate contained no certificates");
            }

            let key: PrivateKeyDer<'static> =
                rustls_pemfile::private_key(&mut BufReader::new(Cursor::new(key_pem)))
                    .context("failed to parse the client private key")?
                    .ok_or_else(|| anyhow!("the client key contained no private key"))?;

            builder
                .with_client_auth_cert(chain, key)
                .context("failed to build a client-authenticated TLS config")?
        }
        // Half a client identity is a misconfiguration, not a fallback to anonymous: silently
        // dropping to no-client-auth against a server that requires mTLS fails at the handshake
        // with nothing naming the cause.
        _ => anyhow::bail!("a client certificate and key must be supplied together, or neither"),
    };

    Ok(PgRustlsConnect::new(config, server_name.map(str::to_string)))
}
