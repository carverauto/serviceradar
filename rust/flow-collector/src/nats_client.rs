//! Shared NATS connection helpers.
//!
//! Both the publisher and the template-store bootstrap need a NATS client
//! configured with the same TLS/creds settings and the same retry semantics.
//! Centralizing here avoids the easy-to-miss mistake of using bare
//! `async_nats::connect(url)` from one of them and silently breaking
//! mTLS-only deployments.

use crate::config::{Config, SecurityMode};
use anyhow::{Context, Result};
use async_nats::{Client, ConnectOptions, jetstream};
use log::{error, info, warn};
use std::cmp::min;
use std::time::Duration;
use tokio::time::sleep;

/// Build [`ConnectOptions`] from the security + creds sections of `Config`.
async fn build_options(config: &Config) -> Result<ConnectOptions> {
    let mut options = ConnectOptions::new();

    if let Some(sec) = &config.security {
        match sec.mode {
            SecurityMode::Mtls => {
                if let Some(ca_path) = sec.ca_file_path() {
                    options = options.add_root_certificates(ca_path);
                }
                if let (Some(cert_path), Some(key_path)) =
                    (sec.cert_file_path(), sec.key_file_path())
                {
                    options = options.add_client_certificate(cert_path, key_path);
                }
            }
            SecurityMode::None => {}
        }
    }

    if let Some(creds_file) = &config.nats_creds_file {
        options = options
            .credentials_file(creds_file)
            .await
            .with_context(|| format!("Failed to load NATS creds file {}", creds_file))?;
    }

    Ok(options)
}

/// Connect once to `url` using `config` for TLS/creds settings, returning
/// both the raw client and a JetStream context.
pub async fn connect_once(
    url: &str,
    config: &Config,
) -> Result<(Client, jetstream::Context)> {
    let options = build_options(config).await?;
    let client = options
        .connect(url)
        .await
        .with_context(|| format!("connecting to NATS at {}", url))?;
    let js = jetstream::new(client.clone());
    Ok((client, js))
}

/// Connect with bounded exponential backoff. Used for both the publisher
/// (which can't make progress without NATS) and the template-store
/// bootstrap (which would crash-loop the pod without retry if NATS is
/// even slightly slow to come up).
///
/// Retries 60 times with backoff 0.5s -> 30s. If all attempts fail, the
/// caller decides whether to give up (publisher) or run degraded (e.g.,
/// template store could fall back to None — currently the bootstrap
/// returns the error to fail fast at startup).
pub async fn connect_with_retry(
    url: &str,
    config: &Config,
    label: &str,
) -> Result<(Client, jetstream::Context)> {
    let mut attempt: u32 = 0;
    let initial_backoff = Duration::from_millis(500);
    let max_backoff = Duration::from_secs(30);
    let mut backoff = initial_backoff;
    let max_attempts = 60;

    loop {
        attempt += 1;
        match connect_once(url, config).await {
            Ok(conn) => {
                if attempt > 1 {
                    info!("NATS [{}] connected on attempt {}", label, attempt);
                }
                return Ok(conn);
            }
            Err(err) => {
                if attempt >= max_attempts {
                    error!(
                        "NATS [{}] connection attempt {} failed: {}. Giving up after {} attempts.",
                        label, attempt, err, max_attempts
                    );
                    return Err(err);
                }
                warn!(
                    "NATS [{}] connection attempt {} failed: {}. Retrying in {:?}...",
                    label, attempt, err, backoff
                );
                sleep(backoff).await;
                let doubled = backoff.checked_mul(2).unwrap_or(max_backoff);
                backoff = min(doubled, max_backoff);
            }
        }
    }
}
