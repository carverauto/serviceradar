use crate::config::Config;
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
    subject_peer_up: String,
    subject_peer_down: String,
    subject_route_update: String,
    subject_route_withdraw: String,
    subject_stats: String,
    subject_unknown: String,
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

        let base = config.subject_prefix.trim_end_matches('.').to_string();

        Ok(Self {
            config,
            client,
            js,
            subject_peer_up: format!("{base}.peer_up"),
            subject_peer_down: format!("{base}.peer_down"),
            subject_route_update: format!("{base}.route_update"),
            subject_route_withdraw: format!("{base}.route_withdraw"),
            subject_stats: format!("{base}.stats"),
            subject_unknown: format!("{base}.unknown"),
        })
    }

    pub async fn publish_raw_event(
        &self,
        event_type: &str,
        event_id: &str,
        payload: Vec<u8>,
    ) -> Result<()> {
        let subject = self.subject_for_event_type(event_type);
        let ack = self.js.publish(subject.to_owned(), payload.into()).await?;

        timeout(Duration::from_millis(self.config.publish_timeout_ms), ack)
            .await
            .with_context(|| {
                format!(
                    "publish ack timeout for subject {} after {}ms",
                    subject, self.config.publish_timeout_ms
                )
            })??;

        info!("published BMP event {} to {}", event_id, subject);
        Ok(())
    }

    #[allow(dead_code)]
    pub fn client(&self) -> &Client {
        &self.client
    }

    fn subject_for_event_type(&self, event_type: &str) -> &str {
        match event_type {
            "peer_up" => self.subject_peer_up.as_str(),
            "peer_down" => self.subject_peer_down.as_str(),
            "route_update" => self.subject_route_update.as_str(),
            "route_withdraw" => self.subject_route_withdraw.as_str(),
            "stats" => self.subject_stats.as_str(),
            _ => self.subject_unknown.as_str(),
        }
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
