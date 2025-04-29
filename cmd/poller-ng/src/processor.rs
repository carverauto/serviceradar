use anyhow::Result;
use async_trait::async_trait;
use reqwest::Client;
use crate::models::types::ServiceStatus;

#[async_trait]
pub trait DataProcessor: Send + Sync {
    // Return the service types this processor handles
    fn handles_service(&self, service_type: &str, service_name: &str) -> bool;

    // Process a service and insert data into Proton
    async fn process_service(&self,
                             poller_id: &str,
                             service: &ServiceStatus,
                             client: &Client,
                             proton_url: &str) -> Result<()>;

    // Set up necessary Proton streams for this processor
    async fn setup_streams(&self, client: &Client, proton_url: &str) -> Result<()>;

    // Return a human-readable name for this processor
    fn name(&self) -> &'static str;

    // Helper method for executing Proton queries
    async fn execute_proton_query(&self, client: &Client, proton_url: &str, query: String) -> Result<()> {
        let response = client.post(format!("{}/api/query", proton_url))
            .header("Content-Type", "application/json")
            .json(&serde_json::json!({
            "sql": query
        }))
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await.unwrap_or_default();
            return Err(anyhow::anyhow!("Proton query failed: {}", error_text));
        }

        Ok(())
    }
}