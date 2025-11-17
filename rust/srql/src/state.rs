use crate::{config::AppConfig, query::QueryEngine};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub query: QueryEngine,
}

impl AppState {
    pub fn new(config: Arc<AppConfig>, query: QueryEngine) -> Self {
        Self { config, query }
    }
}
