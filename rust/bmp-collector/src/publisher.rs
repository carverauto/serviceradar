use crate::config::Config;
use crate::model::BmpRoutingEvent;
use anyhow::{Context, Result};
use async_nats::jetstream::{self, stream::StorageType};
use async_nats::{Client, ConnectOptions};
use log::info;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::timeout;

pub struct Publisher {
    config: Arc<Config>,
    client: Client,
    js: jetstream::Context,
}

impl Publisher {
    pub async fn connect(config: Arc<Config>) -> Result<Self> {
        let mut options = ConnectOptions::new();

        if let Some(creds_file) = &config.nats_creds_file {
            options = options
                .credentials_file(creds_file)
                .await
                .with_context(|| format!("failed loading NATS creds file {}", creds_file))?;
        }

        let client = options
            .connect(&config.nats_url)
            .await
            .with_context(|| format!("failed connecting to NATS {}", config.nats_url))?;

        let js = if let Some(domain) = &config.nats_domain {
            jetstream::with_domain(client.clone(), domain)
        } else {
            jetstream::new(client.clone())
        };

        ensure_stream(&config, &js).await?;

        Ok(Self { config, client, js })
    }

    pub async fn publish_event(&self, event: &BmpRoutingEvent) -> Result<()> {
        let subject = format!(
            "{}.{}",
            self.config.subject_prefix.trim_end_matches('.'),
            event.subject_suffix()
        );

        let payload = serde_json::to_vec(event)?;
        let ack = self.js.publish(subject.clone(), payload.into()).await?;

        timeout(Duration::from_millis(self.config.publish_timeout_ms), ack)
            .await
            .with_context(|| {
                format!(
                    "publish ack timeout for subject {} after {}ms",
                    subject, self.config.publish_timeout_ms
                )
            })??;

        info!("published BMP event {} to {}", event.event_id, subject);
        Ok(())
    }

    #[allow(dead_code)]
    pub fn client(&self) -> &Client {
        &self.client
    }
}

async fn ensure_stream(config: &Config, js: &jetstream::Context) -> Result<()> {
    let required_subjects = config.stream_subjects_resolved();

    match js.get_stream(&config.stream_name).await {
        Ok(mut stream) => {
            let info = stream.info().await?;
            let mut updated_subjects = info.config.subjects.clone();
            let mut changed = false;

            for subject in &required_subjects {
                if !updated_subjects.contains(subject) {
                    updated_subjects.push(subject.clone());
                    changed = true;
                }
            }

            if changed {
                let mut cfg = info.config.clone();
                cfg.subjects = updated_subjects;
                js.update_stream(cfg).await?;
            }
        }
        Err(_) => {
            let cfg = jetstream::stream::Config {
                name: config.stream_name.clone(),
                subjects: required_subjects,
                storage: StorageType::File,
                max_bytes: config.stream_max_bytes,
                max_age: Duration::from_secs(24 * 60 * 60),
                ..Default::default()
            };
            js.get_or_create_stream(cfg).await?;
        }
    }

    Ok(())
}
