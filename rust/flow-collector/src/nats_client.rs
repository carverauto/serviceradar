//! Shared NATS connection helpers.
//!
//! The publisher uses the configured TLS and credential options for every
//! connection attempt. Exporter TLS is independent of this NATS connection.

use crate::config::{Config, SecurityMode};
use anyhow::{Context, Result};
use async_nats::{Client, ConnectOptions, jetstream};

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
pub async fn connect_once(url: &str, config: &Config) -> Result<(Client, jetstream::Context)> {
    let options = build_options(config).await?;
    let client = options
        .connect(url)
        .await
        .with_context(|| format!("connecting to NATS at {}", url))?;
    let js = jetstream::new(client.clone());
    Ok((client, js))
}
