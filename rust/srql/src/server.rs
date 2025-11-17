use crate::{
    config::AppConfig,
    db,
    error::{Result, ServiceError},
    query::{QueryEngine, QueryRequest, QueryResponse, TranslateRequest, TranslateResponse},
    state::{ApiKeyStore, AppState},
};
use axum::{
    extract::State,
    http::HeaderMap,
    routing::{get, post},
    Json, Router,
};
use kvutil::KvClient;
use serde_json::json;
use std::{
    future::Future,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    net::TcpListener,
    sync::{OwnedSemaphorePermit, Semaphore},
    time::{interval, MissedTickBehavior},
};
use tower::{Layer, Service};
use tower_http::trace::TraceLayer;
use tracing::{error, info, warn};

pub struct Server {
    config: Arc<AppConfig>,
    state: AppState,
}

impl Server {
    pub async fn new(config: AppConfig) -> anyhow::Result<Self> {
        let pool = db::connect_pool(&config).await?;
        let config = Arc::new(config);
        let query = QueryEngine::new(pool, Arc::clone(&config));
        let api_keys = initialize_api_keys(&config).await?;
        let state = AppState::new(Arc::clone(&config), query, api_keys);

        Ok(Self { config, state })
    }

    fn router(&self) -> Router {
        Router::new()
            .route("/healthz", get(Self::health))
            .route("/api/query", post(Self::query))
            .route("/translate", post(Self::translate))
            .with_state(self.state.clone())
            .layer(FixedWindowRateLimitLayer::new(
                self.config.rate_limit_max_requests,
                self.config.rate_limit_window,
            ))
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
        enforce_api_key(&headers, &state.api_keys)?;
        let response = state.query.execute_query(request).await;

        match response {
            Ok(rows) => Ok(Json(rows)),
            Err(err) => Err(err),
        }
    }

    async fn translate(
        State(state): State<AppState>,
        headers: HeaderMap,
        Json(request): Json<TranslateRequest>,
    ) -> Result<Json<TranslateResponse>> {
        enforce_api_key(&headers, &state.api_keys)?;
        let response = state.query.translate(request).await?;
        Ok(Json(response))
    }
}

fn enforce_api_key(headers: &HeaderMap, api_keys: &ApiKeyStore) -> Result<()> {
    if let Some(expected) = api_keys.current() {
        let provided = headers
            .get("x-api-key")
            .and_then(|value| value.to_str().ok())
            .map(str::trim);

        if provided != Some(expected.trim()) {
            return Err(ServiceError::Auth);
        }
    }

    Ok(())
}

async fn initialize_api_keys(config: &AppConfig) -> anyhow::Result<ApiKeyStore> {
    let store = ApiKeyStore::new(config.api_key.clone());

    if let Some(kv_key) = &config.api_key_kv_key {
        let mut kv_client = KvClient::connect_from_env().await?;
        match kv_client.get(kv_key).await? {
            Some(value) => match decode_api_key(&value) {
                Some(parsed) => store.set(Some(parsed)),
                None => {
                    anyhow::bail!("invalid API key payload at KV key '{kv_key}'");
                }
            },
            None => anyhow::bail!("KV key '{kv_key}' not found for API key"),
        }

        let watch_key = kv_key.clone();
        let watch_store = store.clone();
        tokio::spawn(async move {
            match KvClient::connect_from_env().await {
                Ok(mut watcher) => {
                    let store_for_watch = watch_store.clone();
                    if let Err(err) = watcher
                        .watch_apply(&watch_key, move |value| {
                            let next = decode_api_key(value);
                            store_for_watch.set(next);
                        })
                        .await
                    {
                        error!(
                            key = %watch_key,
                            ?err,
                            "api key watcher stopped; updates will not be applied"
                        );
                    }
                }
                Err(err) => {
                    error!(
                        key = %watch_key,
                        ?err,
                        "failed to connect to datasvc for API key watch"
                    );
                }
            }
        });
    } else if store.current().is_some() {
        info!("SRQL API key configured via environment");
    } else {
        warn!("SRQL_API_KEY not set; API key authentication disabled");
    }

    Ok(store)
}

fn decode_api_key(raw: &[u8]) -> Option<String> {
    match std::str::from_utf8(raw) {
        Ok(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Err(err) => {
            warn!(error = ?err, "received non-UTF8 API key payload from datasvc");
            None
        }
    }
}

#[derive(Clone)]
struct FixedWindowRateLimitLayer {
    limiter: FixedWindowLimiter,
}

impl FixedWindowRateLimitLayer {
    fn new(max_requests: u64, window: Duration) -> Self {
        Self {
            limiter: FixedWindowLimiter::new(max_requests.max(1), window),
        }
    }
}

impl<S> Layer<S> for FixedWindowRateLimitLayer {
    type Service = FixedWindowRateLimitedService<S>;

    fn layer(&self, inner: S) -> Self::Service {
        FixedWindowRateLimitedService {
            inner,
            limiter: self.limiter.clone(),
        }
    }
}

#[derive(Clone)]
struct FixedWindowRateLimitedService<S> {
    inner: S,
    limiter: FixedWindowLimiter,
}

impl<S, Request> Service<Request> for FixedWindowRateLimitedService<S>
where
    S: Service<Request> + Clone + Send + 'static,
    S::Future: Send + 'static,
    Request: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future =
        Pin<Box<dyn Future<Output = std::result::Result<Self::Response, Self::Error>> + Send>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<std::result::Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, request: Request) -> Self::Future {
        let limiter = self.limiter.clone();
        let mut inner = self.inner.clone();
        Box::pin(async move {
            let _permit = limiter.acquire().await;
            inner.call(request).await
        })
    }
}

#[derive(Clone)]
struct FixedWindowLimiter {
    permits: Arc<Semaphore>,
    max: usize,
    window: Duration,
}

impl FixedWindowLimiter {
    fn new(max_requests: u64, window: Duration) -> Self {
        let limiter = Self {
            permits: Arc::new(Semaphore::new(max_requests as usize)),
            max: max_requests as usize,
            window,
        };
        limiter.spawn_refill_task();
        limiter
    }

    async fn acquire(&self) -> OwnedSemaphorePermit {
        self.permits
            .clone()
            .acquire_owned()
            .await
            .expect("rate limit semaphore closed")
    }

    fn spawn_refill_task(&self) {
        let permits = self.permits.clone();
        let max = self.max;
        let mut ticker = interval(self.window);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        tokio::spawn(async move {
            loop {
                ticker.tick().await;
                let available = permits.available_permits();
                if available < max {
                    permits.add_permits(max - available);
                }
            }
        });
    }
}
