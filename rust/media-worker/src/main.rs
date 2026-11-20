use clap::Parser;
use serviceradar_media_worker::{
    CliArgs, ReadinessState, SystemGpuEnvironmentProbe, WorkerMetrics, build_inference_backend,
    run_nats_worker_loops_with_backend, serve_http_probes,
    verify_startup_capabilities_with_backend,
};
use std::process::ExitCode;
use std::sync::Arc;
use tracing::{error, info};

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cli = CliArgs::parse();
    let config = match cli.into_worker_config() {
        Ok(cfg) => cfg,
        Err(err) => {
            error!(error = %err, "invalid serviceradar-media-worker configuration");
            return ExitCode::from(2);
        }
    };

    let metrics = Arc::new(WorkerMetrics::new());
    let readiness =
        ReadinessState::not_ready("verifying startup capabilities", Arc::clone(&metrics));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    let bound_addr =
        match serve_http_probes(config.listen_addr(), readiness.clone(), shutdown_rx.clone()).await
        {
            Ok(addr) => addr,
            Err(err) => {
                error!(error = %err, "failed starting HTTP health/metrics probe server");
                return ExitCode::from(1);
            }
        };

    let backend = match build_inference_backend(&config) {
        Ok(b) => b,
        Err(err) => {
            readiness.mark_not_ready(err.to_string());
            error!(
                error = %err,
                backend = %config.backend_kind(),
                "failed initializing inference backend; refusing to pull visual indexing jobs"
            );
            let _ = shutdown_tx.send(true);
            return ExitCode::from(1);
        }
    };

    let manifest = match verify_startup_capabilities_with_backend(
        &config,
        &SystemGpuEnvironmentProbe,
        Arc::clone(&backend),
    ) {
        Ok(man) => man,
        Err(err) => {
            // Fail closed with zero silent CPU fallback (`2.2`).
            readiness.mark_not_ready(err.to_string());
            error!(
                error = %err,
                execution_provider = %config.execution_provider(),
                "startup capability admission failed; refusing to pull visual indexing jobs"
            );
            let _ = shutdown_tx.send(true);
            return ExitCode::from(1);
        }
    };

    readiness.mark_ready(manifest.clone());
    info!(
        listen = %bound_addr,
        architecture = %manifest.architecture(),
        inference_backend = %manifest.inference_backend(),
        inference_device = %manifest.inference_device(),
        detector_enabled = manifest.detector_enabled(),
        tracker = %manifest.tracker(),
        dedup_track_crops = manifest.dedup_track_crops(),
        execution_provider = %manifest.execution_provider(),
        gpu_sharing_mode = %manifest.gpu_sharing_mode(),
        embedder_model_id = %manifest.embedder_model_id(),
        embedding_dim = manifest.embedding_dim(),
        "serviceradar-media-worker startup capability admission verified"
    );

    let worker_task = tokio::spawn(run_nats_worker_loops_with_backend(
        config,
        backend,
        metrics,
        shutdown_rx,
    ));

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            info!("received shutdown signal; draining media worker");
            readiness.mark_draining("shutting down");
            let _ = shutdown_tx.send(true);
            ExitCode::SUCCESS
        }
        res = worker_task => {
            readiness.mark_not_ready("worker loop exited");
            let _ = shutdown_tx.send(true);
            match res {
                Ok(Ok(())) => ExitCode::SUCCESS,
                Ok(Err(err)) => {
                    error!(error = %err, "NATS/JetStream media worker loop exited with error");
                    ExitCode::from(1)
                }
                Err(join_err) => {
                    error!(error = %join_err, "media worker task panicked");
                    ExitCode::from(1)
                }
            }
        }
    }
}
