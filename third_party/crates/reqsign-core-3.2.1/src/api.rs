// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use crate::time::Timestamp;
use crate::{BoxedFuture, Context, MaybeSend, Result};
use std::fmt::Debug;
use std::future::Future;
use std::ops::Deref;
use std::time::Duration;

/// A credential that can distinguish cache freshness from exact usability.
///
/// Both checks must reject credentials that lack fields required for authentication.
pub trait SigningCredential: Clone + Debug + Send + Sync + Unpin + 'static {
    /// Return whether a cached credential can be reused without refreshing it.
    ///
    /// Implementations may include a proactive refresh window in this check.
    fn is_valid(&self) -> bool;

    /// Return whether the credential is usable at this exact timestamp.
    ///
    /// Implementations with an expiration time should not add a refresh or
    /// operation-specific buffer here. The default preserves the behavior of
    /// implementations that only provide [`SigningCredential::is_valid`].
    fn is_valid_at(&self, _ts: Timestamp) -> bool {
        self.is_valid()
    }
}

impl<T: SigningCredential> SigningCredential for Option<T> {
    fn is_valid(&self) -> bool {
        let Some(ctx) = self else {
            return false;
        };

        ctx.is_valid()
    }

    fn is_valid_at(&self, ts: Timestamp) -> bool {
        let Some(ctx) = self else {
            return false;
        };

        ctx.is_valid_at(ts)
    }
}

/// ProvideCredential is the trait used by signer to load the credential from the environment.
///`
/// Service may require different credential to sign the request, for example, AWS require
/// access key and secret key, while Google Cloud Storage require token.
pub trait ProvideCredential: Debug + Send + Sync + Unpin + 'static {
    /// Credential returned by this loader.
    ///
    /// Typically, it will be a credential.
    type Credential: Send + Sync + Unpin + 'static;

    /// Load signing credential from current env.
    fn provide_credential(
        &self,
        ctx: &Context,
    ) -> impl Future<Output = Result<Option<Self::Credential>>> + MaybeSend;
}

/// ProvideCredentialDyn is the dyn version of [`ProvideCredential`].
pub trait ProvideCredentialDyn: Debug + Send + Sync + Unpin + 'static {
    /// Credential returned by this loader.
    type Credential: Send + Sync + Unpin + 'static;

    /// Dyn version of [`ProvideCredential::provide_credential`].
    fn provide_credential_dyn<'a>(
        &'a self,
        ctx: &'a Context,
    ) -> BoxedFuture<'a, Result<Option<Self::Credential>>>;
}

impl<T> ProvideCredentialDyn for T
where
    T: ProvideCredential + ?Sized,
{
    type Credential = T::Credential;

    fn provide_credential_dyn<'a>(
        &'a self,
        ctx: &'a Context,
    ) -> BoxedFuture<'a, Result<Option<Self::Credential>>> {
        Box::pin(self.provide_credential(ctx))
    }
}

impl<T> ProvideCredential for std::sync::Arc<T>
where
    T: ProvideCredentialDyn + ?Sized,
{
    type Credential = T::Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        self.deref().provide_credential_dyn(ctx).await
    }
}

/// Service-specific request signing.
///
/// Implementations receive a request URI that is already percent-encoded and ready
/// for transport. They must derive canonical paths, queries, and headers as local
/// views without normalizing or rebuilding the existing wire URI.
///
/// Header authentication must preserve the URI. Query authentication must preserve
/// the existing URI representation and append only protocol-encoded authentication
/// fields. In particular, existing percent escapes, parameter order, duplicate keys,
/// empty values, and literal `+` characters are caller-owned wire data.
pub trait SignRequest: Debug + Send + Sync + Unpin + 'static {
    /// Credential used by this builder.
    ///
    /// Typically, it will be a credential.
    type Credential: Send + Sync + Unpin + 'static;

    /// Return the timestamp through which the credential must remain usable
    /// for the requested signing operation.
    ///
    /// Implementations own the signing clock, the service-specific meaning of
    /// `expires_in`, and any transport, RPC, or artifact-lifetime headroom. This
    /// method must not perform I/O or mutate state. When a deadline depends on an
    /// artifact's signing time, [`SignRequest::sign_request`] must derive both the
    /// deadline check and the artifact from the same captured timestamp.
    fn required_valid_until(
        &self,
        _credential: &Self::Credential,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        Timestamp::now() + expires_in.unwrap_or_default()
    }

    /// Sign a request head.
    ///
    /// On `Err`, an implementation must leave the entire request head unchanged. On
    /// `Ok`, it may change only `req.uri` and `req.headers`; the method, version, and
    /// extensions remain caller-owned. [`crate::Signer`] enforces this commit boundary
    /// when it invokes the implementation, but implementations must also uphold it for
    /// callers that invoke this method directly.
    ///
    /// ## Credential
    ///
    /// The `credential` parameter is the credential required by the signer to sign the request.
    /// Implementations with expiring credentials must validate it against
    /// [`SignRequest::required_valid_until`] before mutating the request or performing
    /// external signing calls. [`crate::Signer`] performs the same validation before
    /// invoking this method, while direct callers rely on the implementation.
    ///
    /// ## Expires In
    ///
    /// The `expires_in` parameter requests a validity duration when the service supports
    /// one. It is not a universal header-versus-query mode selector. Each service and
    /// credential type defines whether the value selects presigning, configures an
    /// expiration, is ignored, or is rejected.
    fn sign_request<'a>(
        &'a self,
        ctx: &'a Context,
        req: &'a mut http::request::Parts,
        credential: Option<&'a Self::Credential>,
        expires_in: Option<Duration>,
    ) -> impl Future<Output = Result<()>> + MaybeSend + 'a;
}

/// SignRequestDyn is the dyn version of [`SignRequest`].
pub trait SignRequestDyn: Debug + Send + Sync + Unpin + 'static {
    /// Credential used by this builder.
    type Credential: Send + Sync + Unpin + 'static;

    /// Dyn version of [`SignRequest::required_valid_until`].
    fn required_valid_until_dyn(
        &self,
        _credential: &Self::Credential,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        Timestamp::now() + expires_in.unwrap_or_default()
    }

    /// Dyn version of [`SignRequest::sign_request`].
    fn sign_request_dyn<'a>(
        &'a self,
        ctx: &'a Context,
        req: &'a mut http::request::Parts,
        credential: Option<&'a Self::Credential>,
        expires_in: Option<Duration>,
    ) -> BoxedFuture<'a, Result<()>>;
}

impl<T> SignRequestDyn for T
where
    T: SignRequest + ?Sized,
{
    type Credential = T::Credential;

    fn required_valid_until_dyn(
        &self,
        credential: &Self::Credential,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        self.required_valid_until(credential, expires_in)
    }

    fn sign_request_dyn<'a>(
        &'a self,
        ctx: &'a Context,
        req: &'a mut http::request::Parts,
        credential: Option<&'a Self::Credential>,
        expires_in: Option<Duration>,
    ) -> BoxedFuture<'a, Result<()>> {
        Box::pin(self.sign_request(ctx, req, credential, expires_in))
    }
}

impl<T> SignRequest for std::sync::Arc<T>
where
    T: SignRequestDyn + ?Sized,
{
    type Credential = T::Credential;

    fn required_valid_until(
        &self,
        credential: &Self::Credential,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        self.deref()
            .required_valid_until_dyn(credential, expires_in)
    }

    async fn sign_request(
        &self,
        ctx: &Context,
        req: &mut http::request::Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        self.deref()
            .sign_request_dyn(ctx, req, credential, expires_in)
            .await
    }
}

/// A chain of credential providers that will be tried in order.
///
/// This is a generic implementation that can be used by any service to chain multiple
/// credential providers together. The chain will try each provider in order until one
/// returns credentials or all providers have been exhausted.
///
/// # Example
///
/// ```no_run
/// use reqsign_core::{ProvideCredentialChain, Context, ProvideCredential, Result};
///
/// #[derive(Debug)]
/// struct MyCredential {
///     token: String,
/// }
///
/// #[derive(Debug)]
/// struct EnvironmentProvider;
///
/// impl ProvideCredential for EnvironmentProvider {
///     type Credential = MyCredential;
///
///     async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
///         // Implementation
///         Ok(None)
///     }
/// }
///
/// # async fn example(ctx: Context) {
/// let chain = ProvideCredentialChain::new()
///     .push(EnvironmentProvider);
///
/// let credentials = chain.provide_credential(&ctx).await;
/// # }
/// ```
pub struct ProvideCredentialChain<C> {
    providers: Vec<Box<dyn ProvideCredentialDyn<Credential = C>>>,
}

impl<C> ProvideCredentialChain<C>
where
    C: Send + Sync + Unpin + 'static,
{
    /// Create a new empty credential provider chain.
    pub fn new() -> Self {
        Self {
            providers: Vec::new(),
        }
    }

    /// Add a credential provider to the chain.
    pub fn push(mut self, provider: impl ProvideCredential<Credential = C> + 'static) -> Self {
        self.providers.push(Box::new(provider));
        self
    }

    /// Add a credential provider to the front of the chain.
    ///
    /// This provider will be tried first before all existing providers.
    pub fn push_front(
        mut self,
        provider: impl ProvideCredential<Credential = C> + 'static,
    ) -> Self {
        self.providers.insert(0, Box::new(provider));
        self
    }

    /// Create a credential provider chain from a vector of providers.
    pub fn from_vec(providers: Vec<Box<dyn ProvideCredentialDyn<Credential = C>>>) -> Self {
        Self { providers }
    }

    /// Get the number of providers in the chain.
    pub fn len(&self) -> usize {
        self.providers.len()
    }

    /// Check if the chain is empty.
    pub fn is_empty(&self) -> bool {
        self.providers.is_empty()
    }
}

impl<C> Default for ProvideCredentialChain<C>
where
    C: Send + Sync + Unpin + 'static,
{
    fn default() -> Self {
        Self::new()
    }
}

impl<C> Debug for ProvideCredentialChain<C>
where
    C: Send + Sync + Unpin + 'static,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProvideCredentialChain")
            .field("providers_count", &self.providers.len())
            .finish()
    }
}

impl<C> ProvideCredential for ProvideCredentialChain<C>
where
    C: Send + Sync + Unpin + 'static,
{
    type Credential = C;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        for provider in &self.providers {
            log::debug!("Trying credential provider: {provider:?}");

            match provider.provide_credential_dyn(ctx).await {
                Ok(Some(cred)) => {
                    log::debug!("Successfully loaded credential from provider: {provider:?}");
                    return Ok(Some(cred));
                }
                Ok(None) => {
                    log::debug!("No credential found in provider: {provider:?}");
                    continue;
                }
                Err(e) => {
                    log::warn!("Error loading credential from provider {provider:?}: {e:?}");
                    // Continue to next provider on error
                    continue;
                }
            }
        }

        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Debug)]
    struct ExactCredential {
        valid_at: Timestamp,
    }

    impl SigningCredential for ExactCredential {
        fn is_valid(&self) -> bool {
            false
        }

        fn is_valid_at(&self, timestamp: Timestamp) -> bool {
            self.valid_at == timestamp
        }
    }

    #[test]
    fn option_forwards_exact_validity_check() {
        let timestamp = Timestamp::from_second(42).expect("timestamp must be valid");
        let credential = Some(ExactCredential {
            valid_at: timestamp,
        });

        assert!(credential.is_valid_at(timestamp));
        assert!(!credential.is_valid_at(timestamp + Duration::from_secs(1)));
        assert!(!None::<ExactCredential>.is_valid_at(timestamp));
    }
}
