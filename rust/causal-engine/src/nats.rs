//! Shared NATS connection (optional mTLS), mirroring `rust/srql` and
//! `rust/consumers/zen`. Returns both the core `Client` (used by the live
//! state-change subscriber) and a JetStream `Context` (used by the verdict
//! emitter).

use std::path::PathBuf;

use async_nats::{jetstream, Client, ConnectOptions};

use crate::config::Config;
use crate::error::{CausalEngineError, Result};

/// Connect to NATS using the engine config, wiring mTLS when cert paths are set.
pub async fn connect(config: &Config) -> Result<(Client, jetstream::Context)> {
    let mut opts = ConnectOptions::new();

    if let Some(ca) = &config.nats_ca_file {
        opts = opts.add_root_certificates(PathBuf::from(ca));
    }
    if let (Some(cert), Some(key)) = (&config.nats_cert_file, &config.nats_key_file) {
        opts = opts.add_client_certificate(PathBuf::from(cert), PathBuf::from(key));
    }

    let client = opts
        .connect(&config.nats_url)
        .await
        .map_err(|e| CausalEngineError::Nats(format!("connect {}: {e}", config.nats_url)))?;

    let jetstream = jetstream::new(client.clone());
    Ok((client, jetstream))
}
