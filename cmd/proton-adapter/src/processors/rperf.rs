use anyhow::Result;
use async_trait::async_trait;
use log::{info, error};
use reqwest::Client;
use chrono::Utc;

use crate::models::types::{ServiceStatus, RperfMetrics};
use crate::processor::DataProcessor;

pub struct RperfProcessor;

#[async_trait]
impl DataProcessor for RperfProcessor {
    fn handles_service(&self, service_type: &str, service_name: &str) -> bool {
        service_type == "grpc" && service_name == "rperf-checker"
    }

    fn name(&self) -> &'static str {
        "rperf"
    }

    async fn process_service(&self,
                             poller_id: &str,
                             service: &ServiceStatus,
                             client: &Client,
                             proton_url: &str) -> Result<()> {
        // Parse rperf metrics
        match serde_json::from_str::<RperfMetrics>(&service.message) {
            Ok(metrics) => {
                info!("Processing rperf data for {}: {} results",
                     poller_id, metrics.results.len());

                let timestamp = Utc::now().to_rfc3339();

                for result in &metrics.results {
                    let query = format!(
                        "INSERT INTO rperf_stream VALUES ('{}', '{}', '{}', {}, {}, {}, {})",
                        timestamp, poller_id, result.target,
                        if result.success { 1 } else { 0 },
                        result.summary.bits_per_second,
                        result.summary.bytes_received,
                        result.summary.duration
                    );
                    self.execute_proton_query(client, proton_url, query).await?;
                }

                Ok(())
            },
            Err(e) => {
                error!("Failed to parse rperf metrics: {}", e);
                Err(anyhow::anyhow!("Failed to parse rperf metrics: {}", e))
            }
        }
    }

    async fn setup_streams(&self, client: &Client, proton_url: &str) -> Result<()> {
        // Create rperf stream
        self.execute_proton_query(client, proton_url,
                                  "CREATE STREAM IF NOT EXISTS rperf_stream (
                timestamp DateTime,
                poller_id String,
                target String,
                success Int8,
                bits_per_second Float64,
                bytes_received UInt64,
                duration Float64
            ) SETTINGS type='memory'".to_string()
        ).await?;

        // Create materialized view
        self.execute_proton_query(client, proton_url,
                                  "CREATE MATERIALIZED VIEW IF NOT EXISTS rperf_1m AS
            SELECT
                window_start,
                poller_id,
                target,
                avg(bits_per_second) AS avg_bits_per_second,
                countIf(success = 1) / count(*) * 100 AS success_rate
            FROM
                tumble(rperf_stream, 1m, watermark=10s)
            GROUP BY
                window_start, poller_id, target".to_string()
        ).await?;

        Ok(())
    }
}