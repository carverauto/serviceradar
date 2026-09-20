/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use std::io::{BufReader, Cursor};
use std::sync::Once;

use rustls::pki_types::PrivateKeyDer;
use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::certs;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_postgres::tls::MakeTlsConnect;
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::MigratorError;

static CRYPTO_PROVIDER: Once = Once::new();

fn ensure_crypto_provider() {
    CRYPTO_PROVIDER.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
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

pub fn postgres_connector(
    ca_pem: &[u8],
    client_cert_pem: Option<&[u8]>,
    client_key_pem: Option<&[u8]>,
    server_name: Option<&str>,
) -> Result<PgRustlsConnect, MigratorError> {
    ensure_crypto_provider();

    let mut root_store = RootCertStore::empty();
    let mut reader = BufReader::new(Cursor::new(ca_pem));
    let mut added = 0usize;
    for cert in certs(&mut reader) {
        let cert = cert.map_err(|err| MigratorError::Postgres(err.to_string()))?;
        root_store
            .add(cert)
            .map_err(|_| MigratorError::Postgres("invalid certificate in the CA bundle".into()))?;
        added += 1;
    }
    if added == 0 {
        return Err(MigratorError::Postgres(
            "the CA bundle contained no certificates".into(),
        ));
    }

    let builder = ClientConfig::builder().with_root_certificates(root_store);
    let config = match (client_cert_pem, client_key_pem) {
        (Some(cert_pem), Some(key_pem)) => {
            let certs = rustls_pemfile::certs(&mut BufReader::new(Cursor::new(cert_pem)))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|err| MigratorError::Postgres(err.to_string()))?;
            let mut keys =
                rustls_pemfile::pkcs8_private_keys(&mut BufReader::new(Cursor::new(key_pem)))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|err| MigratorError::Postgres(err.to_string()))?;
            let key = keys.pop().ok_or_else(|| {
                MigratorError::Postgres("client key PEM contained no PKCS8 key".into())
            })?;
            builder
                .with_client_auth_cert(certs, PrivateKeyDer::Pkcs8(key))
                .map_err(|err| MigratorError::Postgres(err.to_string()))?
        }
        _ => builder.with_no_client_auth(),
    };

    Ok(PgRustlsConnect::new(
        config,
        server_name.map(str::to_string),
    ))
}
