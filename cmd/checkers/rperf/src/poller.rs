use anyhow::Result;
use log::{debug, error, info, warn};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::config::TargetConfig;
use crate::rperf::{RPerfResult, RPerfRunner};

#[derive(Debug)]
pub struct TargetPoller {
    config: TargetConfig,
    default_poll_interval: u64,
    last_result: Arc<Mutex<Option<RPerfResult>>>,
    pub task_handle: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl TargetPoller {
    pub fn new(config: TargetConfig, default_poll_interval: u64) -> Self {
        Self {
            config,
            default_poll_interval,
            last_result: Arc::new(Mutex::new(None)),
            task_handle: Arc::new(Mutex::new(None)),
        }
    }

    pub fn target_name(&self) -> &str {
        &self.config.name
    }

    pub async fn start(&mut self) -> Result<()> {
        let config = self.config.clone();
        let last_result = self.last_result.clone();

        let handle = tokio::spawn(async move {
            info!("Starting poller for target: {}", config.name);
            let runner = RPerfRunner::from_target_config(&config);
            debug!("Running rperf client test for target: {}", config.name);
            match runner.run_test().await {
                Ok(result) => {
                    if result.success {
                        info!(
                            "Test for target '{}' completed successfully: {:.2} Mbps",
                            config.name,
                            result.summary.bits_per_second / 1_000_000.0
                        );
                    } else {
                        warn!(
                            "Test for target '{}' failed: {}",
                            config.name,
                            result.error.as_deref().unwrap_or("Unknown error")
                        );
                    }
                    *last_result.lock().await = Some(result);
                }
                Err(e) => {
                    error!("Error running test for target '{}': {}", config.name, e);
                    *last_result.lock().await = Some(RPerfResult {
                        success: false,
                        error: Some(e.to_string()),
                        results_json: String::new(),
                        summary: Default::default(),
                    });
                }
            }
            info!("Poller for target '{}' completed", config.name);
        });

        *self.task_handle.lock().await = Some(handle);
        Ok(())
    }

    pub async fn stop(&self) -> Result<()> {
        let mut handle = self.task_handle.lock().await;
        if let Some(h) = handle.take() {
            h.abort();
            info!("Stopped poller for target: {}", self.config.name);
        }
        Ok(())
    }

    pub async fn get_last_result(&self) -> Option<RPerfResult> {
        let result = self.last_result.lock().await;
        result.clone()
    }
}