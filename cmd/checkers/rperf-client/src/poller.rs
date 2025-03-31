use anyhow::Result;
use log::{debug, info};
use tokio::time::{Duration, Instant};
use crate::config::TargetConfig;
use crate::rperf::{RPerfResult, RPerfRunner};

#[derive(Debug)] // Add this
pub struct TargetPoller {
    config: TargetConfig,
    runner: RPerfRunner,
    pub(crate) last_result: Option<RPerfResult>,
    default_poll_interval: u64,
    next_run: Instant,
    running: bool,
}

impl TargetPoller {
    pub fn new(config: TargetConfig, default_poll_interval: u64) -> Self {
        let runner = RPerfRunner::from_target_config(&config);
        Self {
            config,
            runner,
            last_result: None,
            default_poll_interval,
            next_run: Instant::now(),
            running: false,
        }
    }

    pub fn target_name(&self) -> &str {
        &self.config.name
    }

    pub fn get_poll_interval(&self) -> Duration {
        Duration::from_secs(self.config.poll_interval.max(self.default_poll_interval))
    }

    pub async fn run_single_test(&mut self) -> Result<RPerfResult> {
        debug!("Running test for target: {}", self.config.name);
        let result = self.runner.run_test().await?;
        self.last_result = Some(result.clone());
        self.next_run = Instant::now() + self.get_poll_interval();
        Ok(result)
    }

    pub async fn start(&mut self) -> Result<()> {
        if self.running {
            return Ok(());
        }
        self.running = true;
        info!("Started poller for target: {}", self.config.name);
        Ok(())
    }

    pub async fn stop(&mut self) -> Result<()> {
        self.running = false;
        info!("Stopped poller for target: {}", self.config.name);
        Ok(())
    }

    pub async fn poll(&mut self) -> Result<Option<RPerfResult>> {
        if !self.running || Instant::now() < self.next_run {
            return Ok(None);
        }
        self.run_single_test().await.map(Some)
    }
}