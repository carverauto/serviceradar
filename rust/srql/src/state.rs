use crate::{config::AppConfig, dual::DualRunner, query::QueryEngine};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub query: QueryEngine,
    pub dual_runner: Option<DualRunner>,
}

impl AppState {
    pub fn new(
        config: Arc<AppConfig>,
        query: QueryEngine,
        dual_runner: Option<DualRunner>,
    ) -> Self {
        Self {
            config,
            query,
            dual_runner,
        }
    }
}
