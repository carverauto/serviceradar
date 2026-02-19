use crate::config::Config;
use crate::model;
use anyhow::{Context, Result};
use arancini_lib::sender::UpdateSender;
use arancini_lib::update::Update;
use async_nats::ConnectOptions;
use async_nats::jetstream::{self, stream::StorageType};
use log::debug;
use std::net::IpAddr;
use std::sync::Arc;
use std::sync::Once;
use std::time::Duration;
use tokio::time::timeout;

#[derive(Clone)]
pub struct Publisher {
    config: Arc<Config>,
    js: jetstream::Context,
}

impl Publisher {
    pub async fn connect(config: Arc<Config>) -> Result<Self> {
        ensure_rustls_provider_installed();
        let mut options = ConnectOptions::new();

        if let Some(creds_file) = &config.nats_creds_file {
            options = options
                .credentials_file(creds_file)
                .await
                .with_context(|| format!("failed loading NATS creds file {}", creds_file))?;
        }

        let has_tls_material = config.nats_tls_ca_cert_path.is_some()
            || (config.nats_tls_client_cert_path.is_some()
                && config.nats_tls_client_key_path.is_some());

        if config.nats_tls_first {
            options = options.tls_first();
        } else if config.nats_tls_required || has_tls_material {
            options = options.require_tls(true);
        }

        if let Some(path) = &config.nats_tls_ca_cert_path {
            options = options.add_root_certificates(path.clone().into());
        }

        if let (Some(cert), Some(key)) = (
            &config.nats_tls_client_cert_path,
            &config.nats_tls_client_key_path,
        ) {
            options = options.add_client_certificate(cert.clone().into(), key.clone().into());
        }

        let client = options
            .connect(&config.nats_url)
            .await
            .with_context(|| format!("failed connecting to NATS {}", config.nats_url))?;

        let js = if let Some(domain) = &config.nats_domain {
            jetstream::with_domain(client, domain)
        } else {
            jetstream::new(client)
        };

        ensure_stream(&config, &js).await?;

        Ok(Self { config, js })
    }

    async fn publish_update(&self, update: Update) -> Result<()> {
        let subject = subject_for_update(&self.config.subject_prefix, &update);
        let payload = serde_json::to_vec(&model::to_payload(&update))?;
        let ack = self.js.publish(subject.clone(), payload.into()).await?;

        timeout(Duration::from_millis(self.config.publish_timeout_ms), ack)
            .await
            .with_context(|| {
                format!(
                    "publish ack timeout for subject {} after {}ms",
                    subject, self.config.publish_timeout_ms
                )
            })??;

        debug!(
            "published arancini update router={} peer={} prefix={}/{} to {}",
            update.router_addr, update.peer_addr, update.prefix_addr, update.prefix_len, subject
        );
        Ok(())
    }
}

impl UpdateSender for Publisher {
    fn send<'a>(
        &'a self,
        update: Update,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send + 'a>> {
        Box::pin(async move { self.publish_update(update).await })
    }
}

fn subject_for_update(base_subject: &str, update: &Update) -> String {
    let router_ip = router_ip_subject_token(update.router_addr);
    let afi_safi = afi_safi_subject_token(update);
    format!(
        "{}.{}.{}.{}",
        base_subject.trim_end_matches('.'),
        router_ip,
        update.peer_asn,
        afi_safi
    )
}

fn router_ip_subject_token(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, c, d] = v4.octets();
            format!("v4_{}_{}_{}_{}", a, b, c, d)
        }
        IpAddr::V6(v6) => {
            if let Some(v4_mapped) = v6.to_ipv4_mapped() {
                return router_ip_subject_token(IpAddr::V4(v4_mapped));
            }

            let segments = v6.segments();
            format!(
                "v6_{:x}_{:x}_{:x}_{:x}_{:x}_{:x}_{:x}_{:x}",
                segments[0],
                segments[1],
                segments[2],
                segments[3],
                segments[4],
                segments[5],
                segments[6],
                segments[7]
            )
        }
    }
}

fn afi_safi_subject_token(update: &Update) -> String {
    let (afi, safi) = if update.announced {
        (update.attrs.mp_reach_afi, update.attrs.mp_reach_safi)
    } else {
        (update.attrs.mp_unreach_afi, update.attrs.mp_unreach_safi)
    };

    let afi = afi.unwrap_or(match update.prefix_addr {
        IpAddr::V4(_) => 1u16,
        IpAddr::V6(_) => 2u16,
    });
    let safi = safi.unwrap_or(1u8);

    format!("{}_{}", afi, safi)
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

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}
