use crate::{config::AppConfig, query::QueryEngine};
use parking_lot::RwLock;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub query: QueryEngine,
    pub api_keys: ApiKeyStore,
}

impl AppState {
    pub fn new(config: Arc<AppConfig>, query: QueryEngine, api_keys: ApiKeyStore) -> Self {
        Self {
            config,
            query,
            api_keys,
        }
    }
}

#[derive(Clone, Default)]
pub struct ApiKeyStore {
    inner: Arc<RwLock<Option<String>>>,
}

impl ApiKeyStore {
    pub fn new(initial: Option<String>) -> Self {
        Self {
            inner: Arc::new(RwLock::new(initial)),
        }
    }

    pub fn current(&self) -> Option<String> {
        self.inner.read().clone()
    }

    pub fn set(&self, next: Option<String>) {
        *self.inner.write() = next;
    }
}
