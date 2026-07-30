/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod token_cache_debug;

use tokio::sync::RwLock;

use crate::types::secret::Secret;

/// Access and refresh tokens issued by an ACL login.
#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct Tokens {
    access: Secret,
    refresh: Secret,
}

impl Tokens {
    pub(crate) fn new(access: Secret, refresh: Secret) -> Self {
        Self { access, refresh }
    }

    pub(crate) fn access(&self) -> &Secret {
        &self.access
    }

    pub(crate) fn refresh(&self) -> &Secret {
        &self.refresh
    }
}

/// Thread-safe cache of the current ACL tokens.
///
/// This is a `tokio::sync::RwLock`, not a `std::sync::RwLock`: the write guard is held
/// across the login RPC, which is an `.await` point. `std::sync::RwLock` guards are not
/// `Send`, so that would not compile.
///
/// Holding the write lock across the RPC is deliberate rather than accidental: it is what
/// collapses a thundering herd of concurrent refreshes into a single login. Callers that
/// arrive during an in-flight refresh block, then observe the refreshed token. Releasing
/// the lock around the RPC would let every caller issue its own login.
pub(crate) struct TokenCache {
    tokens: RwLock<Option<Tokens>>,
}

impl TokenCache {
    pub(crate) fn new() -> Self {
        Self {
            tokens: RwLock::new(None),
        }
    }

    /// Current access token, if any.
    pub(crate) async fn access_token(&self) -> Option<Secret> {
        self.tokens
            .read()
            .await
            .as_ref()
            .map(|tokens| tokens.access().clone())
    }

    /// Whether any tokens are cached.
    pub(crate) async fn is_populated(&self) -> bool {
        self.tokens.read().await.is_some()
    }

    pub(crate) async fn store(&self, tokens: Tokens) {
        *self.tokens.write().await = Some(tokens);
    }

    /// Run `refresh` while holding the write lock, so concurrent callers collapse into a
    /// single refresh.
    ///
    /// If another task refreshed while this one waited for the lock, `refresh` is skipped
    /// and the token that task installed is returned. `previous` is the access token the
    /// caller was using when its request failed; a cached token different from it means
    /// someone else already refreshed.
    pub(crate) async fn refresh_once<F, Fut, E>(
        &self,
        previous: Option<Secret>,
        refresh: F,
    ) -> Result<Secret, E>
    where
        F: FnOnce(Option<Secret>) -> Fut,
        Fut: Future<Output = Result<Tokens, E>>,
    {
        let mut guard = self.tokens.write().await;

        if let Some(current) = guard.as_ref() {
            let already_refreshed = match &previous {
                Some(previous) => current.access() != previous,
                None => true,
            };
            if already_refreshed {
                return Ok(current.access().clone());
            }
        }

        let refresh_token = guard.as_ref().map(|tokens| tokens.refresh().clone());
        let tokens = refresh(refresh_token).await?;
        let access = tokens.access().clone();
        *guard = Some(tokens);

        Ok(access)
    }
}
