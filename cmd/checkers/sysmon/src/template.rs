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

// template.rs - Checker template registration

use anyhow::{Context, Result};
use log::{info, warn};

const DEFAULT_TEMPLATE: &str = include_str!("../config/default_template.json");
const CHECKER_KIND: &str = "sysmon";

/// Registers the checker template with the KV service.
/// This writes the default configuration template to templates/checkers/sysmon.json.
/// Safe to call on every startup - templates are factory defaults and can be overwritten.
pub async fn register_template() -> Result<()> {
    // Try to connect to KV service from environment
    let mut kv_client = match kvutil::KvClient::connect_from_env().await {
        Ok(client) => client,
        Err(e) => {
            warn!(
                "Failed to connect to KV service for template registration: {}. \
                 Skipping template registration (this is non-fatal).",
                e
            );
            return Ok(());
        }
    };

    // Validate the template is valid JSON
    if !serde_json::from_str::<serde_json::Value>(DEFAULT_TEMPLATE).is_ok() {
        anyhow::bail!("Embedded default template is not valid JSON");
    }

    // Write template to KV
    let template_key = format!("templates/checkers/{}.json", CHECKER_KIND);
    match kv_client
        .put(&template_key, DEFAULT_TEMPLATE.as_bytes().to_vec())
        .await
    {
        Ok(_) => {
            info!(
                "Successfully registered checker template at {}",
                template_key
            );
            Ok(())
        }
        Err(e) => {
            warn!(
                "Failed to register template at {}: {}. \
                 This is non-fatal, continuing startup.",
                template_key, e
            );
            Ok(())
        }
    }
}
