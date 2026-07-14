use crate::{Context, Result};
use std::fmt::Debug;
use std::time::Duration;

/// SigningCredential is the trait used by signer as the signing credential.
pub trait SigningCredential: Clone + Debug + Send + Sync + Unpin + 'static {
    /// Check if the signing credential is valid.
    fn is_valid(&self) -> bool;
}

impl<T: SigningCredential> SigningCredential for Option<T> {
    fn is_valid(&self) -> bool {
        let Some(ctx) = self else {
            return false;
        };

        ctx.is_valid()
    }
}

/// ProvideCredential is the trait used by signer to load the credential from the environment.
///`
/// Service may require different credential to sign the request, for example, AWS require
/// access key and secret key, while Google Cloud Storage require token.
#[async_trait::async_trait]
pub trait ProvideCredential: Debug + Send + Sync + Unpin + 'static {
    /// Credential returned by this loader.
    ///
    /// Typically, it will be a credential.
    type Credential: Send + Sync + Unpin + 'static;

    /// Load signing credential from current env.
    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>>;
}

/// SignRequest is the trait used by signer to build the signing request.
#[async_trait::async_trait]
pub trait SignRequest: Debug + Send + Sync + Unpin + 'static {
    /// Credential used by this builder.
    ///
    /// Typically, it will be a credential.
    type Credential: Send + Sync + Unpin + 'static;

    /// Construct the signing request.
    ///
    /// ## Credential
    ///
    /// The `credential` parameter is the credential required by the signer to sign the request.
    ///
    /// ## Expires In
    ///
    /// The `expires_in` parameter specifies the expiration time for the result.
    /// If the signer does not support expiration, it should return an error.
    ///
    /// Implementation details determine how to handle the expiration logic. For instance,
    /// AWS uses a query string that includes an `Expires` parameter.
    async fn sign_request(
        &self,
        ctx: &Context,
        req: &mut http::request::Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()>;
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
/// use async_trait::async_trait;
///
/// #[derive(Debug)]
/// struct MyCredential {
///     token: String,
/// }
///
/// #[derive(Debug)]
/// struct EnvironmentProvider;
///
/// #[async_trait]
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
    providers: Vec<Box<dyn ProvideCredential<Credential = C>>>,
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

    /// Create a credential provider chain from a vector of providers.
    pub fn from_vec(providers: Vec<Box<dyn ProvideCredential<Credential = C>>>) -> Self {
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

#[async_trait::async_trait]
impl<C> ProvideCredential for ProvideCredentialChain<C>
where
    C: Send + Sync + Unpin + 'static,
{
    type Credential = C;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        for provider in &self.providers {
            log::debug!("Trying credential provider: {provider:?}");

            match provider.provide_credential(ctx).await {
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
