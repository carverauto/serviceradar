use anyhow::Result;
use async_nats::jetstream;
use futures::StreamExt;
use log::{debug, info, warn};

use crate::config::Config;
use crate::engine::SharedEngine;

pub async fn watch_rules(engine: SharedEngine, cfg: Config, js: jetstream::Context) -> Result<()> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}/{}/", cfg.agent_id, cfg.stream_name);
    let mut watcher = store.watch(format!("{}>", prefix)).await?;
    info!("watching rules under {}", prefix);
    while let Some(entry) = watcher.next().await {
        if let Ok(ref e) = entry {
            debug!(
                "watch event key={} op={:?} rev={}",
                e.key, e.operation, e.revision
            );
        }
        match entry {
            Ok(e) if matches!(e.operation, jetstream::kv::Operation::Put) => {
                let key = e.key.trim_start_matches(&prefix).trim_end_matches(".json");
                if let Err(err) = engine.get_decision(key).await {
                    warn!("failed to reload rule {}: {}", key, err);
                } else {
                    info!("reloaded rule {} revision {}", key, e.revision);
                }
            }
            Ok(_) => {}
            Err(err) => {
                warn!("watch error: {err}");
                break;
            }
        }
    }
    Ok(())
}