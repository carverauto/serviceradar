#![recursion_limit = "4096"]

pub mod config;
pub mod db;
pub mod error;
pub mod jsonb;
pub mod models;
pub mod pagination;
pub mod parser;
pub mod query;
pub mod schema;
pub mod time;
pub mod tls;

use crate::config::AppConfig;

pub use crate::query::{
    QueryDirection, QueryEngine, QueryRequest, QueryResponse, TranslateRequest, TranslateResponse,
};

/// The standalone `rust/srql` HTTP server (axum, `POST /api/query`) was removed:
/// nothing deployed it (see issue #4873), and web-ng serves the production
/// `/api/query` through `Readers`. The crate survives as a library: the
/// `serviceradar_srql` NIF and `correlation-engine` embed `QueryEngine` /
/// `translate_request` directly.
#[derive(Clone)]
pub struct EmbeddedSrql {
    pub query: QueryEngine,
}

impl EmbeddedSrql {
    pub async fn new(config: AppConfig) -> anyhow::Result<Self> {
        let pool = db::connect_pool(&config).await?;
        let config = std::sync::Arc::new(config);
        Ok(Self {
            query: QueryEngine::new(pool, config),
        })
    }
}
