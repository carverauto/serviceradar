use anyhow::Result;
use async_nats::{jetstream, Client, ConnectOptions};
use log::info;
use std::path::PathBuf;

use crate::config::Config;

pub async fn connect_nats(cfg: &Config) -> Result<(Client, jetstream::Context)> {
    let mut opts = ConnectOptions::new();
    if let Some(sec) = &cfg.security {
        if let Some(ca) = &sec.ca_file {
            opts = opts.add_root_certificates(PathBuf::from(ca));
        }
        if let (Some(cert), Some(key)) = (&sec.cert_file, &sec.key_file) {
            opts = opts.add_client_certificate(PathBuf::from(cert), PathBuf::from(key));
        }
    }
    let client = opts.connect(&cfg.nats_url).await?;
    info!("connected to nats at {}", cfg.nats_url);
    let js = if let Some(domain) = &cfg.domain {
        jetstream::with_domain(client.clone(), domain)
    } else {
        jetstream::new(client.clone())
    };
    Ok((client, js))
}