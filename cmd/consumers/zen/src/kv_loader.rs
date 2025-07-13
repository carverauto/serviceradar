use std::sync::Arc;

use async_nats::jetstream::kv::Store;
use zen_engine::loader::{DecisionLoader, LoaderError, LoaderResponse};
use zen_engine::model::DecisionContent;

#[derive(Debug, Clone)]
pub struct KvLoader {
    store: Store,
    prefix: String,
}

impl KvLoader {
    pub fn new(store: Store, prefix: String) -> Self {
        Self { store, prefix }
    }

    async fn load_from_kv(&self, key: &str) -> LoaderResponse {
        let full_key = if self.prefix.is_empty() {
            format!("{key}.json")
        } else {
            format!("{}/{key}.json", self.prefix.trim_end_matches('/'))
        };
        match self.store.get(full_key).await {
            Ok(Some(bytes)) => {
                let content: DecisionContent =
                    serde_json::from_slice(&bytes).map_err(|e| LoaderError::Internal {
                        key: key.to_string(),
                        source: e.into(),
                    })?;
                Ok(Arc::new(content))
            }
            Ok(None) => Err(LoaderError::NotFound(key.to_string()).into()),
            Err(e) => Err(LoaderError::Internal {
                key: key.to_string(),
                source: e.into(),
            }
            .into()),
        }
    }
}

impl DecisionLoader for KvLoader {
    async fn load<'a>(&'a self, key: &'a str) -> LoaderResponse {
        self.load_from_kv(key).await
    }
}
