//! NATS connection management: connect options, access to the current
//! JetStream context, and generation-counted recovery behind a narrow lock.

use anyhow::Result;
use async_nats::{Client, ConnectOptions, jetstream};
use log::{debug, error, info, warn};

use super::stream::ensure_stream;
use super::{NATSConfig, NATSOutput};

#[derive(Default)]
pub(super) struct ConnectionState {
    pub(super) jetstream: Option<jetstream::Context>,
    /// Bumped after every recovery attempt (success or failure) so
    /// concurrent publishers can tell whether another task already
    /// reconnected while they waited.
    pub(super) generation: u64,
}

impl NATSOutput {
    pub(super) async fn connect(config: &NATSConfig) -> Result<(Client, jetstream::Context)> {
        debug!("Connecting to NATS server: {}", config.url);
        let mut options = ConnectOptions::new();

        if let Some(creds_file) = &config.creds_file {
            debug!("Using NATS creds file: {creds_file:?}");
            options = options.credentials_file(creds_file).await?;
        }

        // Apply CA file if provided
        if let Some(ca_file) = &config.tls_ca {
            debug!("Using TLS CA file: {ca_file:?}");
            options = options.add_root_certificates(ca_file.clone());
        }

        // Apply client certificate and key for mTLS
        if let (Some(cert_file), Some(key_file)) = (&config.tls_cert, &config.tls_key) {
            debug!("Using TLS client certificate: {cert_file:?}, key: {key_file:?}");
            options = options.add_client_certificate(cert_file.clone(), key_file.clone());
        }

        let client = match options.connect(&config.url).await {
            Ok(c) => {
                info!("Connected to NATS server successfully");
                c
            }
            Err(e) => {
                error!("Failed to connect to NATS server: {e}");
                return Err(e.into());
            }
        };

        debug!("Creating JetStream context");
        let jetstream = jetstream::new(client.clone());

        Ok((client, jetstream))
    }

    /// Returns the current JetStream context (cloned; `jetstream::Context`
    /// is internally synchronized), reconnecting first if absent. No lock is
    /// held when this returns.
    pub(super) async fn current_jetstream(&self) -> Result<(jetstream::Context, u64)> {
        let observed_generation = {
            let state = self.state.read().await;
            if let Some(js) = &state.jetstream {
                return Ok((js.clone(), state.generation));
            }
            state.generation
        };

        warn!(
            "JetStream context missing before publish; attempting reconnect for stream '{}'",
            self.config.stream
        );
        self.recover(observed_generation).await
    }

    /// Reconnects and re-ensures the stream behind the narrow `recovery`
    /// lock. Publishers that lost the recovery race reuse the fresh context
    /// instead of reconnecting again; if the racing recovery failed, this
    /// attempt proceeds with its own reconnect.
    async fn recover(&self, observed_generation: u64) -> Result<(jetstream::Context, u64)> {
        let _guard = self.recovery.lock().await;

        {
            let state = self.state.read().await;
            // If a concurrent recovery succeeded while we waited for the
            // lock, reuse its context. If it ran and failed (generation
            // bumped, context still absent), fall through and try again
            // ourselves.
            if state.generation != observed_generation
                && let Some(js) = &state.jetstream
            {
                return Ok((js.clone(), state.generation));
            }
        }

        warn!(
            "Attempting to recover NATS JetStream context for stream '{}'",
            self.config.stream
        );
        match Self::connect(&self.config).await {
            Ok((_client, jetstream)) => {
                ensure_stream(&jetstream, &self.config).await?;
                let mut state = self.state.write().await;
                state.jetstream = Some(jetstream.clone());
                state.generation += 1;
                let generation = state.generation;
                drop(state);
                info!(
                    "Successfully recovered JetStream stream '{}'",
                    self.config.stream
                );
                Ok((jetstream, generation))
            }
            Err(e) => {
                error!(
                    "Failed to reconnect to NATS while recovering stream '{}': {e}",
                    self.config.stream
                );
                let mut state = self.state.write().await;
                state.jetstream = None;
                state.generation += 1;
                Err(e)
            }
        }
    }

    /// Best-effort recovery after a publish/ack error that indicates the
    /// stream is missing. Failures are logged, never propagated — the
    /// original publish error is what the caller reports.
    pub(super) async fn try_recover_after_error(&self, observed_generation: u64, what: &str) {
        warn!(
            "JetStream stream '{}' missing during {what}; attempting recovery",
            self.config.stream
        );
        if let Err(recover_err) = self.recover(observed_generation).await {
            error!(
                "Failed to recover JetStream stream '{}' after {what} error: {recover_err}",
                self.config.stream
            );
        }
    }

    pub(super) fn publish_error_indicates_missing_stream(err: &dyn std::fmt::Display) -> bool {
        err.to_string()
            .to_ascii_lowercase()
            .contains("no stream found")
    }
}
