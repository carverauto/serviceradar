//! Configuration watching functionality for hot-reload support.

use crate::{ConfigFormat, Result};
use kvutil::{self, KvClient};
use serde::{Deserialize, Serialize};
use std::fs;
use tokio::sync::mpsc;

/// Watches a KV key for changes and provides updates to the service.
pub struct ConfigWatcher<T> {
    receiver: mpsc::UnboundedReceiver<T>,
}

impl<T> ConfigWatcher<T>
where
    T: Serialize + for<'de> Deserialize<'de> + Send + 'static,
{
    /// Create a new config watcher that monitors the given KV key.
    pub async fn new(
        kv_client: &mut KvClient,
        kv_key: String,
        format: ConfigFormat,
        service_name: String,
        pinned_path: Option<String>,
    ) -> Result<Self> {
        let (tx, rx) = mpsc::unbounded_channel();
        let pinned_path = pinned_path.filter(|s| !s.is_empty());
        let service_name_clone = service_name.clone();
        let mut last_bytes: Option<Vec<u8>> = None;
        kv_client
            .watch_apply(&kv_key, {
                let pinned_path = pinned_path.clone();
                move |bytes| {
                    if let Some(prev) = last_bytes.as_ref() {
                        if prev.as_slice() == bytes {
                            return;
                        }
                    }

                    match parse_config::<T>(bytes, format) {
                        Ok(mut cfg) => {
                            if let Err(err) =
                                apply_pinned_overlay(&mut cfg, pinned_path.as_deref(), format)
                            {
                                tracing::warn!(
                                    service = %service_name_clone,
                                    error = %err,
                                    "failed to apply pinned config to KV update"
                                );
                                return;
                            }

                            last_bytes = Some(bytes.to_vec());
                            if tx.send(cfg).is_err() {
                                tracing::debug!(
                                    service = %service_name_clone,
                                    "config watcher receiver dropped; stopping watch task"
                                );
                            }
                        }
                        Err(err) => {
                            tracing::warn!(
                                service = %service_name_clone,
                                error = %err,
                                "failed to parse config update from KV"
                            );
                        }
                    }
                }
            })
            .await?;
        Ok(Self { receiver: rx })
    }

    /// Check if a new config is available.
    /// Returns None if no update is available.
    pub async fn recv(&mut self) -> Option<T> {
        self.receiver.recv().await
    }

    /// Try to receive a config update without blocking.
    pub fn try_recv(&mut self) -> std::result::Result<T, mpsc::error::TryRecvError> {
        self.receiver.try_recv()
    }
}

fn parse_config<T>(data: &[u8], format: ConfigFormat) -> Result<T>
where
    T: for<'de> Deserialize<'de>,
{
    match format {
        ConfigFormat::Json => {
            let config: T = serde_json::from_slice(data)?;
            Ok(config)
        }
        ConfigFormat::Toml => {
            let s = std::str::from_utf8(data)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            let config: T = toml::from_str(s)?;
            Ok(config)
        }
    }
}

fn apply_pinned_overlay<T>(
    cfg: &mut T,
    pinned_path: Option<&str>,
    format: ConfigFormat,
) -> Result<()>
where
    T: Serialize + for<'de> Deserialize<'de>,
{
    let Some(path) = pinned_path else {
        return Ok(());
    };

    if path.is_empty() {
        return Ok(());
    }

    let data = fs::read(path)?;
    match format {
        ConfigFormat::Json => kvutil::overlay_json(cfg, &data)?,
        ConfigFormat::Toml => kvutil::overlay_toml(cfg, &data)?,
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Serialize, Deserialize, PartialEq)]
    struct TestConfig {
        value: i32,
    }

    #[test]
    fn test_parse_config_json() {
        let data = b"{\"value\": 42}";
        let config: TestConfig = parse_config(data, ConfigFormat::Json).unwrap();
        assert_eq!(config.value, 42);
    }

    #[test]
    fn test_parse_config_toml() {
        let data = b"value = 99";
        let config: TestConfig = parse_config(data, ConfigFormat::Toml).unwrap();
        assert_eq!(config.value, 99);
    }
}
