//! Workload API client for fetching SPIFFE X.509 and JWT material.
//!
//! `WorkloadApiClient` provides one-shot RPCs (fetch SVIDs/bundles) and streaming RPCs for
//! receiving updates as material rotates. Higher-level types like [`crate::X509Source`] handle
//! reconnection and provide an always-up-to-date view of the X.509 context.
//!
//! A single workload may be issued **multiple SVIDs** by the SPIFFE Workload API. When this
//! happens, the agent may attach an optional **hint** to each SVID to help distinguish identities.
//! Hints are **not part of the cryptographic material** and have no security meaning.

#[cfg(feature = "x509")]
mod x509;

mod header;
#[cfg(feature = "jwt")]
mod jwt;

use crate::transport::connect;
use crate::transport::Endpoint;
use crate::workload_api::client::header::MetadataAdder;
use crate::workload_api::error::WorkloadApiError;
use crate::workload_api::pb::workload::spiffe_workload_api_client::SpiffeWorkloadApiClient;

#[cfg(all(test, feature = "jwt"))]
use crate::{JwtSvid, SpiffeId};
#[cfg(all(test, feature = "jwt"))]
use std::{future::Future, pin::Pin, sync::Arc};

pub use header::InterceptorFn;

#[cfg(all(test, feature = "jwt"))]
pub(crate) type JwtFetchTestHook = Arc<
    dyn Fn(
            Vec<String>,
            Option<SpiffeId>,
        ) -> Pin<Box<dyn Future<Output = Result<JwtSvid, WorkloadApiError>> + Send>>
        + Send
        + Sync
        + 'static,
>;

/// Client for the SPIFFE Workload API.
///
/// Provides one-shot calls and streaming updates for X.509 and JWT SVIDs and bundles.
/// For an always-up-to-date, shareable source of X.509 material with automatic reconnection,
/// see [`crate::X509Source`].
#[cfg_attr(not(all(test, feature = "jwt")), derive(Debug))]
#[derive(Clone)]
pub struct WorkloadApiClient {
    endpoint: Endpoint,
    client: SpiffeWorkloadApiClient<
        tonic::service::interceptor::InterceptedService<tonic::transport::Channel, MetadataAdder>,
    >,
    #[cfg(all(test, feature = "jwt"))]
    jwt_fetch_hook: Option<JwtFetchTestHook>,
}

#[cfg(all(test, feature = "jwt"))]
impl std::fmt::Debug for WorkloadApiClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkloadApiClient")
            .field("endpoint", &self.endpoint)
            .field("client", &self.client)
            .finish_non_exhaustive()
    }
}

impl WorkloadApiClient {
    /// Returns the configured Workload API endpoint.
    pub const fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// Connects to the Workload API using a parsed [`Endpoint`].
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the endpoint cannot be reached or the gRPC
    /// connection fails.
    pub async fn connect(endpoint: Endpoint) -> Result<Self, WorkloadApiError> {
        let channel = connect(&endpoint).await?;
        Ok(Self {
            endpoint,
            client: SpiffeWorkloadApiClient::with_interceptor(channel, MetadataAdder::new(None)),
            #[cfg(all(test, feature = "jwt"))]
            jwt_fetch_hook: None,
        })
    }

    /// Connects to the Workload API using the given endpoint string.
    ///
    /// Examples:
    /// - `unix:/tmp/spire-agent/public/api.sock` or `unix:///tmp/spire-agent/public/api.sock`
    /// - `tcp:127.0.0.1:8081` or `tcp://127.0.0.1:8081`
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the endpoint string is invalid, the endpoint
    /// cannot be reached, or the gRPC connection fails.
    pub async fn connect_to(endpoint: impl AsRef<str>) -> Result<Self, WorkloadApiError> {
        let endpoint = Endpoint::parse(endpoint.as_ref())?;
        Self::connect(endpoint).await
    }

    /// Connects to the Workload API using `SPIFFE_ENDPOINT_SOCKET`.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the endpoint socket is not set, cannot be
    /// reached, or the gRPC connection fails.
    pub async fn connect_env() -> Result<Self, WorkloadApiError> {
        let endpoint = crate::workload_api::endpoint::from_env()?;
        Self::connect(endpoint).await
    }

    /// Creates a client from an existing gRPC channel.
    ///
    /// This is primarily intended for tests or advanced transport customization (e.g., custom TLS
    /// configuration, load balancing, or connection pooling). The provided channel must be
    /// configured to connect to the actual SPIFFE endpoint.
    ///
    /// For normal usage, use [`WorkloadApiClient::connect`] or [`WorkloadApiClient::connect_env`].
    ///
    /// # Example (TCP endpoint)
    ///
    /// ```no_run
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// # use spiffe::{WorkloadApiClient, transport::Endpoint};
    /// # use tonic::transport::Channel;
    /// let endpoint = "tcp://127.0.0.1:8080".parse::<Endpoint>()?;
    /// let channel = Channel::from_shared("http://127.0.0.1:8080")?
    ///     .connect()
    ///     .await?;
    /// let client = WorkloadApiClient::new_with_channel(endpoint, channel);
    /// # Ok(())
    /// # }
    /// ```
    pub fn new_with_channel(endpoint: Endpoint, channel: tonic::transport::Channel) -> Self {
        Self {
            endpoint,
            client: SpiffeWorkloadApiClient::with_interceptor(channel, MetadataAdder::new(None)),
            #[cfg(all(test, feature = "jwt"))]
            jwt_fetch_hook: None,
        }
    }

    /// Creates a client from an existing gRPC channel with a custom
    /// per-RPC metadata interceptor.
    ///
    /// The `interceptor` is called on every RPC to inject custom metadata
    /// (e.g. K8s service account tokens for identity-server authentication).
    /// The standard `workload.spiffe.io: true` header is always added
    /// automatically.
    ///
    /// This is the primary constructor for identity-server, which requires
    /// per-RPC authentication metadata over TLS+TCP (unlike standard SPIRE
    /// which uses Unix domain sockets with implicit OS-level auth).
    pub fn new_with_channel_and_interceptor(
        endpoint: Endpoint,
        channel: tonic::transport::Channel,
        interceptor: InterceptorFn,
    ) -> Self {
        Self {
            endpoint,
            client: SpiffeWorkloadApiClient::with_interceptor(
                channel,
                MetadataAdder::new(Some(interceptor)),
            ),
            #[cfg(all(test, feature = "jwt"))]
            jwt_fetch_hook: None,
        }
    }

    #[cfg(all(test, feature = "jwt-source"))]
    pub(crate) fn new_with_jwt_fetch_hook(endpoint: Endpoint, hook: JwtFetchTestHook) -> Self {
        let channel = tonic::transport::Endpoint::from_static("http://127.0.0.1:1").connect_lazy();

        Self {
            endpoint,
            client: SpiffeWorkloadApiClient::with_interceptor(channel, MetadataAdder::new(None)),
            jwt_fetch_hook: Some(hook),
        }
    }
}

impl WorkloadApiClient {
    /// Extracts the first message from a streaming gRPC response.
    ///
    /// Returns `WorkloadApiError::EmptyResponse` if the stream ends without yielding a message.
    async fn first_message<T>(mut stream: tonic::Streaming<T>) -> Result<T, WorkloadApiError> {
        stream
            .message()
            .await?
            .ok_or(WorkloadApiError::EmptyResponse)
    }
}
