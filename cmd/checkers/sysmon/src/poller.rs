/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use anyhow::Result;
use log::{debug, info};
use tokio::time::{Duration, Instant};
use crate::config::TargetConfig;

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