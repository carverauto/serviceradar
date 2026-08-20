/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod dgraph_client_admin;
mod dgraph_client_auth;
mod dgraph_client_debug;
mod dgraph_client_txn;
mod no_certificate_verification;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use proto_dgraph::api;
use proto_dgraph::api::dgraph_client::DgraphClient as DgraphStub;
use crate::types::ca_certificate::CaCertificate;
use tonic::transport::{Certificate, Channel, ClientTlsConfig, Endpoint};
use tonic::{Code, Request};

use crate::errors::connect_error::ConnectError;
use crate::errors::dgraph_error::DgraphError;
use crate::types::client_config::ClientConfig;
use crate::types::dgraph_client::no_certificate_verification::NoCertificateVerification;
use crate::types::tls_mode::TlsMode;
use crate::types::token_cache::TokenCache;

/// A transaction-aware client for a Dgraph cluster.
///
/// Cloning is cheap: clones share one set of gRPC channels and one token cache, so a
/// client can be cloned freely across tasks. The type is `Send + Sync`.
///
/// Unlike the Go client there is no `close()`. Channels are released when the last clone
/// is dropped, which is also why the Go client's no-op `Close()` has no equivalent here.
#[derive(Clone)]
pub struct DgraphClient {
    inner: Arc<ClientInner>,
}

pub(crate) struct ClientInner {
    channels: Vec<Channel>,
    /// Round-robin cursor. The Go client calls this "round robin" but actually uses
    /// `rand.Intn`; this is the real thing.
    cursor: AtomicUsize,
    tokens: TokenCache,
    config: ClientConfig,
}

impl DgraphClient {
    /// Connect using a `dgraph://` connection string.
    ///
    /// Logs in when the string carries credentials, then probes the cluster so that a
    /// misconfigured endpoint fails here rather than on first use. gRPC channels connect
    /// lazily, so without the probe the first error would surface at an arbitrary later
    /// call.
    pub async fn connect(connection_string: &str) -> Result<Self, DgraphError> {
        let config = ClientConfig::from_connection_string(connection_string)?;
        Self::from_config(config).await
    }

    /// Connect using an explicit configuration.
    pub async fn from_config(config: ClientConfig) -> Result<Self, DgraphError> {
        if config.endpoints().is_empty() {
            return Err(ConnectError::NoEndpoints().into());
        }

        if config.tls_mode() == TlsMode::RequireNoVerify {
            tracing::warn!(
                "connecting with sslmode=require: TLS certificate verification is DISABLED, so \
                 the server is not authenticated; prefer sslmode=verify-ca"
            );
        }

        let channels = config
            .endpoints()
            .iter()
            .map(|endpoint| Self::build_channel(endpoint, config.tls_mode(), config.ca_certificate()))
            .collect::<Result<Vec<_>, ConnectError>>()?;

        let client = Self {
            inner: Arc::new(ClientInner {
                channels,
                cursor: AtomicUsize::new(0),
                tokens: TokenCache::new(),
                config,
            }),
        };

        if client.inner.config.has_acl_credentials() {
            client.login().await?;
        }

        client.probe().await?;

        Ok(client)
    }

    fn build_channel(
        endpoint: &str,
        tls: TlsMode,
        ca: Option<&CaCertificate>,
    ) -> Result<Channel, ConnectError> {
        let scheme = if tls.is_tls() { "https" } else { "http" };
        let uri = format!("{scheme}://{endpoint}");

        let builder = Endpoint::from_shared(uri)
            .map_err(|err| ConnectError::InvalidEndpoint(endpoint.to_string(), err.to_string()))?;

        let builder = match tls {
            TlsMode::Disable => builder,
            TlsMode::VerifyCa => {
                // A supplied CA REPLACES the system roots rather than joining them, which is
                // what `sslrootcert` means everywhere else and the only reading that lets a
                // private CA be a security boundary: adding to the public roots would leave
                // any public CA able to impersonate the cluster.
                let tls_config = match ca {
                    Some(ca) => {
                        let pem = ca.pem().map_err(|err| {
                            ConnectError::Tls(format!("reading CA certificate: {err}"))
                        })?;
                        ClientTlsConfig::new().ca_certificate(Certificate::from_pem(pem))
                    }
                    None => ClientTlsConfig::new().with_native_roots(),
                };
                builder
                    .tls_config(tls_config)
                    .map_err(|err| ConnectError::Tls(err.to_string()))?
            }
            TlsMode::RequireNoVerify => {
                // tonic's API takes `Arc<dyn ServerCertVerifier>`, so this is the one
                // place the crate uses a trait object. It is confined to this call and
                // never appears in a public signature.
                let provider = rustls::crypto::ring::default_provider();
                let verifier = Arc::new(NoCertificateVerification::new(Arc::new(provider)));
                builder
                    .tls_config_with_verifier(ClientTlsConfig::new(), verifier)
                    .map_err(|err| ConnectError::Tls(err.to_string()))?
            }
        };

        // Lazy: nothing connects until the first RPC. The probe below is what turns a
        // broken endpoint into an error at construction time.
        Ok(builder.connect_lazy())
    }

    /// Verify the cluster is reachable and accepting requests.
    async fn probe(&self) -> Result<(), DgraphError> {
        let mut stub = self.stub();
        match stub.check_version(Request::new(api::Check {})).await {
            Ok(_) => Ok(()),
            Err(status) => {
                let message = status.message().to_string();
                // The server signals "still starting" in the message; the Go client makes
                // callers string-match for it. Translate once, here, into a typed variant
                // so no caller ever has to.
                if message.contains("Please retry") {
                    Err(ConnectError::ClusterNotReady(status.code(), message).into())
                } else if status.code() == Code::Unavailable {
                    Err(ConnectError::Transport(message).into())
                } else {
                    Err(ConnectError::ProbeFailed(status.code(), message).into())
                }
            }
        }
    }

    /// Next channel in round-robin order.
    pub(crate) fn next_channel(&self) -> Channel {
        let index = self.inner.cursor.fetch_add(1, Ordering::Relaxed);
        let slot = index % self.inner.channels.len().max(1);

        // `get` rather than indexing: the constructor guarantees a non-empty channel list,
        // but no public API should be one refactor away from a panic.
        match self.inner.channels.get(slot) {
            Some(channel) => channel.clone(),
            // Unreachable while the constructor rejects empty endpoint lists. Falling back
            // to the first channel keeps this total; if that is also absent the list is
            // empty, which construction forbids.
            None => {
                self.inner.channels.first().cloned().unwrap_or_else(|| {
                    Endpoint::from_static("http://127.0.0.1:9080").connect_lazy()
                })
            }
        }
    }

    /// A generated stub bound to the next channel.
    pub(crate) fn stub(&self) -> DgraphStub<Channel> {
        DgraphStub::new(self.next_channel())
    }

    pub(crate) fn tokens(&self) -> &TokenCache {
        &self.inner.tokens
    }

    pub(crate) fn config(&self) -> &ClientConfig {
        &self.inner.config
    }

    /// Number of endpoints this client round-robins across.
    pub fn endpoint_count(&self) -> usize {
        self.inner.channels.len()
    }
}
