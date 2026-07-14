use crate::{Context, ProvideCredential, Result, SignRequest, SigningCredential};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Signer is the main struct used to sign the request.
#[derive(Clone, Debug)]
pub struct Signer<K: SigningCredential> {
    ctx: Context,
    loader: Arc<dyn ProvideCredential<Credential = K>>,
    builder: Arc<dyn SignRequest<Credential = K>>,
    credential: Arc<Mutex<Option<K>>>,
}

impl<K: SigningCredential> Signer<K> {
    /// Create a new signer.
    pub fn new(
        ctx: Context,
        loader: impl ProvideCredential<Credential = K>,
        builder: impl SignRequest<Credential = K>,
    ) -> Self {
        Self {
            ctx,

            loader: Arc::new(loader),
            builder: Arc::new(builder),
            credential: Arc::new(Mutex::new(None)),
        }
    }

    /// Replace the context while keeping credential provider and request signer.
    pub fn with_context(mut self, ctx: Context) -> Self {
        self.ctx = ctx;
        self
    }

    /// Replace the credential provider while keeping context and request signer.
    pub fn with_credential_provider(
        mut self,
        provider: impl ProvideCredential<Credential = K>,
    ) -> Self {
        self.loader = Arc::new(provider);
        self.credential = Arc::new(Mutex::new(None)); // Clear cached credential
        self
    }

    /// Replace the request signer while keeping context and credential provider.
    pub fn with_request_signer(mut self, signer: impl SignRequest<Credential = K>) -> Self {
        self.builder = Arc::new(signer);
        self
    }

    /// Signing request.
    pub async fn sign(
        &self,
        req: &mut http::request::Parts,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let credential = self.credential.lock().expect("lock poisoned").clone();
        let credential = if credential.is_valid() {
            credential
        } else {
            let ctx = self.loader.provide_credential(&self.ctx).await?;
            *self.credential.lock().expect("lock poisoned") = ctx.clone();
            ctx
        };

        self.builder
            .sign_request(&self.ctx, req, credential.as_ref(), expires_in)
            .await
    }
}
