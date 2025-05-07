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
 *
 */


// cmd/poller-ng/src/processor.rs

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