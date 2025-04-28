// src/processors/sysmon.rs
use anyhow::Result;
use async_trait::async_trait;
use log::{info, error};
use reqwest::Client;

use crate::models::types::{ServiceStatus, SysmonMetrics};
use crate::processor::DataProcessor;

pub struct SysmonProcessor;

#[async_trait]
impl DataProcessor for SysmonProcessor {
    fn handles_service(&self, service_type: &str, service_name: &str) -> bool {
        service_type == "grpc" && service_name == "sysmon"
    }

    async fn process_service(&self, poller_id: &str, service: &ServiceStatus, client: &Client, proton_url: &str) -> Result<()> {
        match serde_json::from_str::<SysmonMetrics>(&service.message) {
            Ok(metrics) => {
                info!("Processing sysmon data for {}: {} CPUs, {} disks, memory data",
                     poller_id, metrics.cpus.len(), metrics.disks.len());

                let mut queries = Vec::new();
                for cpu in &metrics.cpus {
                    queries.push(format!(
                        "INSERT INTO sysmon_cpu_stream VALUES ('{}', '{}', {}, {})",
                        metrics.timestamp, poller_id, cpu.core_id, cpu.usage_percent
                    ));
                }
                for disk in &metrics.disks {
                    queries.push(format!(
                        "INSERT INTO sysmon_disk_stream VALUES ('{}', '{}', '{}', {}, {})",
                        metrics.timestamp, poller_id, disk.mount_point, disk.used_bytes, disk.total_bytes
                    ));
                }
                queries.push(format!(
                    "INSERT INTO sysmon_memory_stream VALUES ('{}', '{}', {}, {})",
                    metrics.timestamp, poller_id, metrics.memory.used_bytes, metrics.memory.total_bytes
                ));

                let batch_query = queries.join(";\n");
                self.execute_proton_query(client, proton_url, batch_query).await?;
                Ok(())
            },
            Err(e) => {
                error!("Failed to parse sysmon metrics: {}", e);
                Err(anyhow::anyhow!("Failed to parse sysmon metrics: {}", e))
            }
        }
    }

    async fn setup_streams(&self, client: &Client, proton_url: &str) -> Result<()> {
        self.execute_proton_query(client, proton_url,
                                  "CREATE STREAM IF NOT EXISTS sysmon_cpu_stream (
                timestamp DateTime,
                poller_id String,
                core_id Int32,
                usage_percent Float32
            ) SETTINGS type='memory'".to_string()
        ).await?;

        self.execute_proton_query(client, proton_url,
                                  "CREATE STREAM IF NOT EXISTS sysmon_disk_stream (
                timestamp DateTime,
                poller_id String,
                mount_point String,
                used_bytes UInt64,
                total_bytes UInt64
            ) SETTINGS type='memory'".to_string()
        ).await?;

        self.execute_proton_query(client, proton_url,
                                  "CREATE STREAM IF NOT EXISTS sysmon_memory_stream (
                timestamp DateTime,
                poller_id String,
                used_bytes UInt64,
                total_bytes UInt64
            ) SETTINGS type='memory'".to_string()
        ).await?;

        self.execute_proton_query(client, proton_url,
                                  "CREATE MATERIALIZED VIEW IF NOT EXISTS cpu_usage_1m AS
            SELECT
                window_start,
                poller_id,
                core_id,
                avg(usage_percent) AS avg_usage
            FROM
                tumble(sysmon_cpu_stream, 1m, watermark=10s)
            GROUP BY
                window_start, poller_id, core_id".to_string()
        ).await?;

        self.execute_proton_query(client, proton_url,
                                  "CREATE MATERIALIZED VIEW IF NOT EXISTS disk_usage_1m AS
            SELECT
                window_start,
                poller_id,
                mount_point,
                max(used_bytes) AS used_bytes,
                max(total_bytes) AS total_bytes,
                max(used_bytes) / max(total_bytes) * 100 AS usage_percent
            FROM
                tumble(sysmon_disk_stream, 1m, watermark=10s)
            GROUP BY
                window_start, poller_id, mount_point".to_string()
        ).await?;

        self.execute_proton_query(client, proton_url,
                                  "CREATE MATERIALIZED VIEW IF NOT EXISTS memory_usage_1m AS
            SELECT
                window_start,
                poller_id,
                max(used_bytes) AS used_bytes,
                max(total_bytes) AS total_bytes,
                max(used_bytes) / max(total_bytes) * 100 AS usage_percent
            FROM
                tumble(sysmon_memory_stream, 1m, watermark=10s)
            GROUP BY
                window_start, poller_id".to_string()
        ).await?;

        Ok(())
    }

    fn name(&self) -> &'static str {
        "sysmon"
    }
}