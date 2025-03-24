// src/poller.rs
pub struct TargetPoller {
    config: TargetConfig,
    default_poll_interval: u64,
    last_result: Arc<Mutex<Option<RPerfResult>>>,
}

impl TargetPoller {
    pub fn new(config: TargetConfig, default_poll_interval: u64) -> Self {
        Self {
            config,
            default_poll_interval,
            last_result: Arc::new(Mutex::new(None)),
        }
    }

    pub fn target_name(&self) -> &str {
        &self.config.name
    }

    pub async fn run_single_test(&mut self) -> Result<RPerfResult> {
        debug!("Running rperf client test for target: {}", self.config.name);
        let runner = RPerfRunner::from_target_config(&self.config);
        let result = runner.run_test().await?;
        *self.last_result.lock().await = Some(result.clone());
        Ok(result)
    }

    pub async fn stop(&self) -> Result<()> {
        // No ongoing task to stop; just log
        info!("Poller for target {} stopped", self.config.name);
        Ok(())
    }

    pub async fn get_last_result(&self) -> Option<RPerfResult> {
        self.last_result.lock().await.clone()
    }
}