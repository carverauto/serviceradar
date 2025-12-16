#![recursion_limit = "4096"]

pub mod config;
pub mod db;
pub mod error;
pub mod models;
pub mod pagination;
pub mod parser;
pub mod query;
pub mod schema;
pub mod server;
pub mod state;
pub mod telemetry;
pub mod time;

use crate::{config::AppConfig, server::Server};

pub use crate::query::{
    QueryDirection, QueryEngine, QueryRequest, QueryResponse, TranslateRequest, TranslateResponse,
};

/// Bootstraps the SRQL service using environment configuration.
pub async fn run() -> anyhow::Result<()> {
    let config = AppConfig::from_env()?;
    Server::new(config).await?.run().await
}

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
