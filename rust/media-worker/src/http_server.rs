//! Axum HTTP health, capability readiness, and Prometheus metrics server (`2.2`, `5.2`).
//!
//! Serves `/healthz`, `/readyz` (`200 OK` JSON capability manifest when ready;
//! `503 Service Unavailable` when failed or draining), and `/metrics` on `0.0.0.0:8096`.

use crate::capability::CapabilityManifest;
use crate::errors::MediaWorkerError;
use crate::metrics::WorkerMetrics;
use axum::extract::State;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use parking_lot::RwLock;
use serde::Serialize;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;

#[derive(Debug, Clone)]
enum ReadinessPhase {
    Ready(Box<CapabilityManifest>),
    NotReady(String),
    Draining(String),
}

/// Shared readiness and metrics state for the HTTP probe listener.
#[derive(Debug, Clone)]
pub struct ReadinessState {
    phase: Arc<RwLock<ReadinessPhase>>,
    metrics: Arc<WorkerMetrics>,
}

impl ReadinessState {
    pub fn ready(manifest: CapabilityManifest, metrics: Arc<WorkerMetrics>) -> Self {
        Self {
            phase: Arc::new(RwLock::new(ReadinessPhase::Ready(Box::new(manifest)))),
            metrics,
        }
    }

    pub fn not_ready(reason: impl Into<String>, metrics: Arc<WorkerMetrics>) -> Self {
        Self {
            phase: Arc::new(RwLock::new(ReadinessPhase::NotReady(reason.into()))),
            metrics,
        }
    }

    pub fn mark_ready(&self, manifest: CapabilityManifest) {
        *self.phase.write() = ReadinessPhase::Ready(Box::new(manifest));
    }

    pub fn mark_draining(&self, reason: impl Into<String>) {
        *self.phase.write() = ReadinessPhase::Draining(reason.into());
    }

    pub fn mark_not_ready(&self, reason: impl Into<String>) {
        *self.phase.write() = ReadinessPhase::NotReady(reason.into());
    }

    pub fn is_ready(&self) -> bool {
        matches!(&*self.phase.read(), ReadinessPhase::Ready(_))
    }

    pub fn metrics(&self) -> &Arc<WorkerMetrics> {
        &self.metrics
    }
}

#[derive(Serialize)]
struct HealthzResponse<'a> {
    status: &'a str,
    service: &'a str,
}

#[derive(Serialize)]
struct UnavailableReadyzResponse<'a> {
    status: &'a str,
    reason: &'a str,
}

/// Constructs the Axum router serving `/healthz`, `/readyz`, and `/metrics`.
pub fn build_http_router(state: ReadinessState) -> Router {
    Router::new()
        .route("/healthz", get(handle_healthz))
        .route("/readyz", get(handle_readyz))
        .route("/metrics", get(handle_metrics))
        .with_state(state)
}

/// Binds and serves the HTTP probe listener until `shutdown` resolves.
pub async fn serve_http_probes(
    listen_addr: SocketAddr,
    state: ReadinessState,
    shutdown: tokio::sync::watch::Receiver<bool>,
) -> Result<SocketAddr, MediaWorkerError> {
    let listener = TcpListener::bind(listen_addr).await.map_err(|err| {
        MediaWorkerError::storage_transport(format!(
            "failed binding media-worker HTTP probe listener on {listen_addr}: {err}"
        ))
    })?;
    let bound = listener.local_addr().map_err(|err| {
        MediaWorkerError::storage_transport(format!(
            "failed reading bound HTTP probe listener address: {err}"
        ))
    })?;
    let router = build_http_router(state);
    let mut rx = shutdown;

    tokio::spawn(async move {
        let _ = axum::serve(listener, router)
            .with_graceful_shutdown(async move {
                while !*rx.borrow_and_update() {
                    if rx.changed().await.is_err() {
                        break;
                    }
                }
            })
            .await;
    });

    Ok(bound)
}

async fn handle_healthz() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(HealthzResponse {
            status: "ok",
            service: "serviceradar-media-worker",
        }),
    )
}

async fn handle_readyz(State(state): State<ReadinessState>) -> Response {
    let snapshot = state.phase.read().clone();
    match snapshot {
        ReadinessPhase::Ready(manifest) => (StatusCode::OK, Json(*manifest)).into_response(),
        ReadinessPhase::NotReady(reason) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(UnavailableReadyzResponse {
                status: "not_ready",
                reason: &reason,
            }),
        )
            .into_response(),
        ReadinessPhase::Draining(reason) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(UnavailableReadyzResponse {
                status: "draining",
                reason: &reason,
            }),
        )
            .into_response(),
    }
}

async fn handle_metrics(State(state): State<ReadinessState>) -> Response {
    match state.metrics.render_prometheus_text() {
        Ok(body) => {
            let mut resp = (StatusCode::OK, body).into_response();
            resp.headers_mut().insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/plain; version=0.0.4; charset=utf-8"),
            );
            resp
        }
        Err(err) => (StatusCode::INTERNAL_SERVER_ERROR, err.to_string()).into_response(),
    }
}
