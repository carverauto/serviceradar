#![recursion_limit = "256"]

pub mod config;
pub mod db;
pub mod dual;
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

/// Bootstraps the SRQL service using environment configuration.
pub async fn run() -> anyhow::Result<()> {
    let config = AppConfig::from_env()?;
    Server::new(config).await?.run().await
}
