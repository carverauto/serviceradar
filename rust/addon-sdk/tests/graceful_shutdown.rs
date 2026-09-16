// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! SIGTERM must end `serve_on_listener` within a bounded grace period even while
//! the host holds a long-lived stream open. tonic's graceful drain waits for every
//! open stream, and the agent keeps the telemetry stream open for the life of the
//! add-on, so an unbounded drain never returns: the process outlives its RPC
//! server, the supervisor reports it unhealthy but cannot restart it (it only
//! restarts on exit), and every upgrade ends in SIGKILL with no final checkpoint.

use std::time::Duration;

use addon_sdk::pb::addon_service_client::AddonServiceClient;
use addon_sdk::pb::{StreamTelemetryRequest, TelemetryBatch};
use addon_sdk::{Addon, ConfigureResult, Health, HealthStatus, Info, TelemetryStream};
use async_trait::async_trait;
use tokio::net::{UnixListener, UnixStream};
use tokio_stream::StreamExt as _;

struct HoldsTelemetryOpen;

#[async_trait]
impl Addon for HoldsTelemetryOpen {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info {
            id: "holds-open".into(),
            version: "0.0.1".into(),
            capabilities: vec![],
        })
    }

    async fn configure(&self, _config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        Ok(ConfigureResult {
            config_hash: String::new(),
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        Ok(Health {
            status: HealthStatus::Healthy,
            version: "0.0.1".into(),
            degradation_reason: String::new(),
            details: Default::default(),
        })
    }

    fn stream_telemetry(&self) -> TelemetryStream {
        // Like the anomaly add-on's verdict stream: yields only when there is
        // something to say, and there never is.
        Box::pin(tokio_stream::pending::<Result<TelemetryBatch, tonic::Status>>())
    }
}

#[tokio::test]
async fn sigterm_ends_serve_within_the_grace_period_despite_an_open_stream() {
    let dir = tempfile::tempdir().expect("tempdir");
    let sock_path = dir.path().join("addon.sock");
    let listener = UnixListener::bind(&sock_path).expect("bind unix socket");

    let server = tokio::spawn(async move {
        addon_sdk::serve_on_listener(HoldsTelemetryOpen, listener, None).await
    });

    let connect_path = sock_path.clone();
    let channel = tonic::transport::Endpoint::try_from("http://localhost")
        .unwrap()
        .connect_with_connector(tower::service_fn(move |_: tonic::transport::Uri| {
            let p = connect_path.clone();
            async move {
                let unix = UnixStream::connect(p).await?;
                Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(unix))
            }
        }))
        .await
        .expect("client connects over the unix socket");
    let mut client = AddonServiceClient::new(channel);

    // Open the telemetry stream and keep it open, as the agent does.
    let mut stream = client
        .stream_telemetry(StreamTelemetryRequest::default())
        .await
        .expect("StreamTelemetry opens")
        .into_inner();
    assert!(
        tokio::time::timeout(Duration::from_millis(200), stream.next())
            .await
            .is_err(),
        "the stream must be open and silent"
    );

    // The host's shutdown signal.
    let status = std::process::Command::new("kill")
        .args(["-TERM", &std::process::id().to_string()])
        .status()
        .expect("kill runs");
    assert!(status.success());

    let result = tokio::time::timeout(Duration::from_secs(5), server)
        .await
        .expect("serve_on_listener must return within the grace period after SIGTERM")
        .expect("server task joins");
    assert!(result.is_ok(), "serve returned an error: {result:?}");
}
