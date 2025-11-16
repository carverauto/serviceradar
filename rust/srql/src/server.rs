use crate::{
    config::AppConfig,
    db,
    dual::DualRunner,
    error::{Result, ServiceError},
    query::{QueryEngine, QueryRequest, QueryResponse, TranslateRequest, TranslateResponse},
    state::AppState,
};
use axum::{
    extract::State,
    http::HeaderMap,
    routing::{get, post},
    Json, Router,
};
use serde_json::json;
use std::sync::Arc;
use tokio::net::TcpListener;
use tower_http::trace::TraceLayer;
use tracing::info;

pub struct Server {
    config: Arc<AppConfig>,
    state: AppState,
}

impl Server {
    pub async fn new(config: AppConfig) -> anyhow::Result<Self> {
        let pool = db::connect_pool(&config).await?;
        let config = Arc::new(config);
        let query = QueryEngine::new(pool, Arc::clone(&config));
        let dual_runner = match config.dual_run.clone() {
            Some(cfg) => Some(DualRunner::new(cfg)?),
            None => None,
        };
        let state = AppState::new(Arc::clone(&config), query, dual_runner);

        Ok(Self { config, state })
    }

    fn router(&self) -> Router {
        Router::new()
            .route("/healthz", get(Self::health))
            .route("/api/query", post(Self::query))
            .route("/translate", post(Self::translate))
            .with_state(self.state.clone())
            .layer(TraceLayer::new_for_http())
    }

    pub async fn run(self) -> anyhow::Result<()> {
        let addr = self.config.listen_addr;
        let listener = TcpListener::bind(addr).await?;
        info!(%addr, "SRQL listening");
        axum::serve(listener, self.router()).await?;
        Ok(())
    }

    async fn health() -> Json<serde_json::Value> {
        Json(json!({ "status": "ok" }))
    }

    async fn query(
        State(state): State<AppState>,
        headers: HeaderMap,
        Json(request): Json<QueryRequest>,
    ) -> Result<Json<QueryResponse>> {
        enforce_api_key(&headers, &state.config)?;
        let payload = serde_json::to_value(&request).unwrap_or_default();
        let response = state.query.execute_query(request.clone()).await;

        match response {
            Ok(rows) => {
                if let Some(runner) = state.dual_runner.clone() {
                    let local_rows = rows.results.clone();
                    tokio::spawn(async move {
                        runner.compare(payload, &local_rows).await;
                    });
                }
                Ok(Json(rows))
            }
            Err(err) => Err(err),
        }
    }

    async fn translate(
        State(state): State<AppState>,
        headers: HeaderMap,
        Json(request): Json<TranslateRequest>,
    ) -> Result<Json<TranslateResponse>> {
        enforce_api_key(&headers, &state.config)?;
        let response = state.query.translate(request).await?;
        Ok(Json(response))
    }
}

fn enforce_api_key(headers: &HeaderMap, config: &AppConfig) -> Result<()> {
    if let Some(expected) = &config.api_key {
        let provided = headers
            .get("x-api-key")
            .and_then(|value| value.to_str().ok());

        if provided != Some(expected.as_str()) {
            return Err(ServiceError::Auth);
        }
    }

    Ok(())
}
