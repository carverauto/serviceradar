use anyhow::Result;
use reqwest::{Client, StatusCode};
use serde::Deserialize;
use std::{sync::Arc, time::Duration};
use tracing::{debug, warn};

#[derive(Debug, Clone)]
pub struct DualRunConfig {
    pub url: String,
    pub timeout: Duration,
}

#[derive(Clone)]
pub struct DualRunner {
    client: Client,
    config: Arc<DualRunConfig>,
}

impl DualRunner {
    pub fn new(config: DualRunConfig) -> Result<Self> {
        let client = Client::builder().timeout(config.timeout).build()?;

        Ok(Self {
            client,
            config: Arc::new(config),
        })
    }

    pub async fn compare(&self, payload: serde_json::Value, primary_rows: &[serde_json::Value]) {
        match self.dispatch(payload).await {
            Ok(other_rows) => {
                if other_rows.len() != primary_rows.len() {
                    warn!(
                        expected = other_rows.len(),
                        actual = primary_rows.len(),
                        "dual-run result count mismatch"
                    );
                    return;
                }

                for (idx, (lhs, rhs)) in primary_rows.iter().zip(other_rows.iter()).enumerate() {
                    if lhs != rhs {
                        warn!(index = idx, "dual-run row mismatch");
                        break;
                    }
                }
            }
            Err(err) => {
                debug!(error = %err, "dual-run comparison failed");
            }
        }
    }

    async fn dispatch(&self, payload: serde_json::Value) -> Result<Vec<serde_json::Value>> {
        let response = self
            .client
            .post(format!(
                "{}/api/query",
                self.config.url.trim_end_matches('/')
            ))
            .json(&payload)
            .send()
            .await?;

        if response.status() != StatusCode::OK {
            anyhow::bail!("legacy SRQL returned status {}", response.status());
        }

        #[derive(Deserialize)]
        struct LegacyResponse {
            results: Vec<serde_json::Value>,
        }

        let body: LegacyResponse = response.json().await?;
        Ok(body.results)
    }
}
