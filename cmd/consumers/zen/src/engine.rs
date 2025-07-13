use anyhow::Result;
use async_nats::jetstream;
use log::info;
use zen_engine::{handler::custom_node_adapter::NoopCustomNode, DecisionEngine};

use crate::config::Config;
use crate::kv_loader::KvLoader;

pub type EngineType = DecisionEngine<KvLoader, NoopCustomNode>;
pub type SharedEngine = std::sync::Arc<EngineType>;

pub async fn build_engine(cfg: &Config, js: &jetstream::Context) -> Result<SharedEngine> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}", cfg.agent_id);
    let loader = KvLoader::new(store, prefix);
    info!("initialized decision engine with bucket {}", cfg.kv_bucket);
    Ok(std::sync::Arc::new(DecisionEngine::new(
        std::sync::Arc::new(loader),
        std::sync::Arc::new(NoopCustomNode::default()),
    )))
}