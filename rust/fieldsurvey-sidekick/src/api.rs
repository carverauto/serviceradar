use crate::capture_control::{ActiveCaptureStream, CaptureControl, CaptureStreamType};
use crate::config::SidekickConfig;
use crate::live_capture::{CaptureRequest, spawn_capture};
use crate::observation::SidekickObservation;
use crate::radio::{
    ChannelHopRequest, MonitorPrepareExecution, MonitorPreparePlan, MonitorPrepareRequest,
    RadioDiscovery, RadioInterface, build_channel_hop_request, build_monitor_prepare_plan,
    execute_monitor_prepare_plan, spawn_channel_hopper,
};
use crate::runtime_config::{
    RuntimeConfigUpdateRequest, SidekickRuntimeConfig, SidekickRuntimeConfigResponse,
    load_runtime_config, save_runtime_config,
};
use crate::spectrum::{
    SpectrumSummary, SpectrumSweep, SpectrumSweepRequest, spawn_hackrf_sweep, summarize_sweep,
};
use crate::wifi::{
    WifiUplinkExecution, WifiUplinkPlan, WifiUplinkRequest, build_wifi_uplink_plan,
    execute_wifi_uplink_plan,
};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct AppState {
    config: Arc<SidekickConfig>,
    capture_control: Arc<CaptureControl>,
}

impl AppState {
    pub fn new(config: SidekickConfig) -> Self {
        Self {
            config: Arc::new(config),
            capture_control: CaptureControl::new(),
        }
    }

    pub fn config(&self) -> &SidekickConfig {
        &self.config
    }

    pub fn capture_control(&self) -> Arc<CaptureControl> {
        Arc::clone(&self.capture_control)
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/status", get(status))
        .route("/pairing/claim", post(pairing_claim))
        .route("/config", get(get_config).put(put_config))
        .route("/capture/stop", post(stop_capture))
        .route("/observations/stream", get(observation_stream))
        .route("/spectrum/stream", get(spectrum_stream))
        .route("/spectrum/summary-stream", get(spectrum_summary_stream))
        .route("/radios/monitor-plan", post(monitor_plan))
        .route("/radios/prepare-monitor", post(prepare_monitor))
        .route("/wifi/uplink-plan", post(wifi_uplink_plan))
        .route("/wifi/configure-uplink", post(configure_wifi_uplink))
        .with_state(state)
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct HealthResponse {
    pub ok: bool,
}

#[derive(Debug, Serialize)]
pub struct StatusResponse {
    pub service: &'static str,
    pub version: &'static str,
    pub capture_running: bool,
    pub active_streams: Vec<ActiveCaptureStream>,
    pub iw_available: bool,
    pub radios: Vec<RadioInterface>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct MonitorPrepareResponse {
    pub plan: MonitorPreparePlan,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct MonitorPrepareExecutionResponse {
    pub result: MonitorPrepareExecution,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct WifiUplinkPlanResponse {
    pub plan: WifiUplinkPlan,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct WifiUplinkExecutionResponse {
    pub result: WifiUplinkExecution,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CaptureStopResponse {
    pub stopped: bool,
    pub generation: u64,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct PairingClaimRequest {
    pub device_id: String,
    #[serde(default)]
    pub device_name: Option<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct PairingClaimResponse {
    pub sidekick_id: String,
    pub device_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    pub token: String,
    pub paired_at_unix_secs: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ErrorResponse {
    pub error: String,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct ObservationStreamQuery {
    pub interface_name: String,
    #[serde(default = "default_sidekick_id")]
    pub sidekick_id: String,
    #[serde(default = "default_radio_id")]
    pub radio_id: String,
    pub frequencies_mhz: Option<String>,
    #[serde(default = "default_hop_interval_ms")]
    pub hop_interval_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObservationStreamRequest {
    pub capture: CaptureRequest,
    pub channel_hop: Option<ChannelHopRequest>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct SpectrumStreamQuery {
    #[serde(default = "default_sidekick_id")]
    pub sidekick_id: String,
    #[serde(default = "default_sdr_id")]
    pub sdr_id: String,
    pub serial_number: Option<String>,
    #[serde(default = "default_spectrum_frequency_min_mhz")]
    pub frequency_min_mhz: u32,
    #[serde(default = "default_spectrum_frequency_max_mhz")]
    pub frequency_max_mhz: u32,
    #[serde(default = "default_spectrum_bin_width_hz")]
    pub bin_width_hz: u32,
    #[serde(default = "default_spectrum_lna_gain_db")]
    pub lna_gain_db: u8,
    #[serde(default = "default_spectrum_vga_gain_db")]
    pub vga_gain_db: u8,
    #[serde(default = "default_spectrum_sweep_count")]
    pub sweep_count: u32,
}

async fn healthz() -> Json<HealthResponse> {
    Json(HealthResponse { ok: true })
}

async fn status(State(state): State<AppState>) -> Json<StatusResponse> {
    Json(build_status_response(&state))
}

async fn get_config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<SidekickRuntimeConfigResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    load_runtime_config(state.config())
        .await
        .map(|config| Json(config.response()))
        .map_err(internal_error)
}

async fn put_config(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RuntimeConfigUpdateRequest>,
) -> Result<Json<SidekickRuntimeConfigResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let current = load_runtime_config(state.config())
        .await
        .map_err(internal_error)?;
    let updated = current
        .apply_update(request)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    save_runtime_config(state.config(), &updated)
        .await
        .map_err(internal_error)?;

    Ok(Json(updated.response()))
}

async fn pairing_claim(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PairingClaimRequest>,
) -> Result<Json<PairingClaimResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_setup_auth(&state, &headers)?;
    let current = load_runtime_config(state.config())
        .await
        .map_err(internal_error)?;
    let token = generate_pairing_token().map_err(internal_error)?;
    let token_hash = hash_token(&token);
    let paired_at_unix_secs = unix_secs_now();
    let updated = current
        .upsert_paired_device(
            request.device_id,
            request.device_name,
            token_hash,
            paired_at_unix_secs,
        )
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    let paired_device = updated
        .paired_devices
        .iter()
        .find(|device| device.paired_at_unix_secs == paired_at_unix_secs)
        .cloned()
        .ok_or_else(|| internal_error("paired device was not persisted".to_string()))?;
    save_runtime_config(state.config(), &updated)
        .await
        .map_err(internal_error)?;

    Ok(Json(PairingClaimResponse {
        sidekick_id: updated.sidekick_id,
        device_id: paired_device.device_id,
        device_name: paired_device.device_name,
        token,
        paired_at_unix_secs,
    }))
}

async fn stop_capture(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<CaptureStopResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let generation = state.capture_control().stop_all();

    Ok(Json(CaptureStopResponse {
        stopped: true,
        generation,
    }))
}

async fn monitor_plan(
    Json(request): Json<MonitorPrepareRequest>,
) -> Result<Json<MonitorPrepareResponse>, (StatusCode, Json<ErrorResponse>)> {
    build_monitor_prepare_response(request)
        .map(Json)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))
}

async fn prepare_monitor(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<MonitorPrepareRequest>,
) -> Result<Json<MonitorPrepareExecutionResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    prepare_monitor_response(request)
        .await
        .map(Json)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))
}

async fn wifi_uplink_plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<WifiUplinkRequest>,
) -> Result<Json<WifiUplinkPlanResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    build_wifi_uplink_plan(&request)
        .map(|plan| Json(WifiUplinkPlanResponse { plan }))
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))
}

async fn configure_wifi_uplink(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<WifiUplinkRequest>,
) -> Result<Json<WifiUplinkExecutionResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let result = execute_wifi_uplink_plan(request)
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;

    if let Some(saved_config) = &result.saved_config {
        let current = load_runtime_config(state.config())
            .await
            .map_err(internal_error)?;
        let updated = SidekickRuntimeConfig {
            wifi_uplink: Some(saved_config.clone()),
            ..current
        };
        save_runtime_config(state.config(), &updated)
            .await
            .map_err(internal_error)?;
    }

    Ok(Json(WifiUplinkExecutionResponse { result }))
}

async fn observation_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ObservationStreamQuery>,
    ws: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let request = build_observation_stream_request(query)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    let capture_control = state.capture_control();

    Ok(ws.on_upgrade(move |socket| stream_observations(socket, request, capture_control)))
}

async fn spectrum_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SpectrumStreamQuery>,
    ws: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let request = build_spectrum_sweep_request(query)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    let capture_control = state.capture_control();

    Ok(ws.on_upgrade(move |socket| stream_spectrum(socket, request, capture_control)))
}

async fn spectrum_summary_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SpectrumStreamQuery>,
    ws: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let request = build_spectrum_sweep_request(query)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    let capture_control = state.capture_control();

    Ok(ws.on_upgrade(move |socket| stream_spectrum_summaries(socket, request, capture_control)))
}

pub fn build_status_response(state: &AppState) -> StatusResponse {
    let inventory = RadioDiscovery::new(
        state.config.sysfs_net_path.clone(),
        state.config.interfaces.clone(),
    )
    .discover();
    let active_streams = state.capture_control.active_streams();
    let capture_running = !active_streams.is_empty();

    StatusResponse {
        service: "serviceradar-fieldsurvey-sidekick",
        version: env!("CARGO_PKG_VERSION"),
        capture_running,
        active_streams,
        iw_available: inventory.iw_available,
        radios: inventory.radios,
    }
}

pub fn build_monitor_prepare_response(
    request: MonitorPrepareRequest,
) -> Result<MonitorPrepareResponse, String> {
    build_monitor_prepare_plan(request).map(|plan| MonitorPrepareResponse { plan })
}

pub async fn prepare_monitor_response(
    request: MonitorPrepareRequest,
) -> Result<MonitorPrepareExecutionResponse, String> {
    let dry_run = request.dry_run;
    let plan = build_monitor_prepare_plan(request)?;
    let result = execute_monitor_prepare_plan(plan, dry_run).await?;

    Ok(MonitorPrepareExecutionResponse { result })
}

pub fn build_capture_request(query: ObservationStreamQuery) -> Result<CaptureRequest, String> {
    Ok(build_observation_stream_request(query)?.capture)
}

pub fn build_observation_stream_request(
    query: ObservationStreamQuery,
) -> Result<ObservationStreamRequest, String> {
    let interface_name = query.interface_name.trim();
    if interface_name.is_empty() {
        return Err("interface_name is required".to_string());
    }

    let sidekick_id = query.sidekick_id.trim();
    if sidekick_id.is_empty() {
        return Err("sidekick_id is required".to_string());
    }

    let radio_id = query.radio_id.trim();
    if radio_id.is_empty() {
        return Err("radio_id is required".to_string());
    }

    let capture = CaptureRequest {
        interface_name: interface_name.to_string(),
        sidekick_id: sidekick_id.to_string(),
        radio_id: radio_id.to_string(),
    };

    let channel_hop = match query.frequencies_mhz {
        Some(raw_frequencies) => {
            build_channel_hop_request(interface_name, &raw_frequencies, query.hop_interval_ms)?
        }
        None => None,
    };

    Ok(ObservationStreamRequest {
        capture,
        channel_hop,
    })
}

pub fn build_spectrum_sweep_request(
    query: SpectrumStreamQuery,
) -> Result<SpectrumSweepRequest, String> {
    let sidekick_id = query.sidekick_id.trim();
    if sidekick_id.is_empty() {
        return Err("sidekick_id is required".to_string());
    }

    let sdr_id = query.sdr_id.trim();
    if sdr_id.is_empty() {
        return Err("sdr_id is required".to_string());
    }

    if query.frequency_min_mhz >= query.frequency_max_mhz {
        return Err("frequency_min_mhz must be lower than frequency_max_mhz".to_string());
    }

    if !(2_445..=5_000_000).contains(&query.bin_width_hz) {
        return Err("bin_width_hz must be between 2445 and 5000000".to_string());
    }

    if query.lna_gain_db > 40 || !query.lna_gain_db.is_multiple_of(8) {
        return Err("lna_gain_db must be 0-40 in 8 dB steps".to_string());
    }

    if query.vga_gain_db > 62 || !query.vga_gain_db.is_multiple_of(2) {
        return Err("vga_gain_db must be 0-62 in 2 dB steps".to_string());
    }

    if query.sweep_count == 0 {
        return Err("sweep_count must be greater than zero".to_string());
    }

    Ok(SpectrumSweepRequest {
        sidekick_id: sidekick_id.to_string(),
        sdr_id: sdr_id.to_string(),
        serial_number: query
            .serial_number
            .map(|serial| serial.trim().to_string())
            .filter(|serial| !serial.is_empty()),
        frequency_min_mhz: query.frequency_min_mhz,
        frequency_max_mhz: query.frequency_max_mhz,
        bin_width_hz: query.bin_width_hz,
        lna_gain_db: query.lna_gain_db,
        vga_gain_db: query.vga_gain_db,
        sweep_count: query.sweep_count,
    })
}

async fn stream_observations(
    mut socket: WebSocket,
    request: ObservationStreamRequest,
    capture_control: Arc<CaptureControl>,
) {
    let target = request.capture.interface_name.clone();
    let _registration = capture_control.register(CaptureStreamType::RfObservation, target);
    let mut stop_rx = capture_control.subscribe_stop();
    let channel_hopper = request.channel_hop.map(spawn_channel_hopper);
    let mut observations = spawn_capture(request.capture);
    let mut pending = Vec::with_capacity(128);
    let mut flush_interval = tokio::time::interval(Duration::from_millis(200));
    flush_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            result = observations.recv() => {
                let Some(result) = result else {
                    let _ = send_observation_batch(&mut socket, &mut pending).await;
                    break;
                };

                match result {
                    Ok(observation) => {
                        pending.push(observation);
                        if pending.len() >= 128
                            && !send_observation_batch(&mut socket, &mut pending).await {
                                break;
                            }
                    }
                    Err(error) => {
                        let _ = send_observation_batch(&mut socket, &mut pending).await;
                        let _ = socket
                            .send(Message::Text(format!(r#"{{"error":"{error}"}}"#)))
                            .await;
                        break;
                    }
                };
            }
            _ = flush_interval.tick() => {
                if !send_observation_batch(&mut socket, &mut pending).await {
                    break;
                }
            }
            stop_result = stop_rx.changed() => {
                let _ = stop_result;
                let _ = send_observation_batch(&mut socket, &mut pending).await;
                let _ = socket
                    .send(Message::Text(r#"{"event":"capture_stopped"}"#.to_string()))
                    .await;
                break;
            }
            client_message = socket.recv() => {
                if client_message.is_none() {
                    break;
                }
            }
        }
    }

    if let Some(channel_hopper) = channel_hopper {
        channel_hopper.abort();
    }
}

async fn send_observation_batch(
    socket: &mut WebSocket,
    pending: &mut Vec<SidekickObservation>,
) -> bool {
    if pending.is_empty() {
        return true;
    }

    let payload = match crate::arrow_stream::encode_observations_ipc(pending) {
        Ok(payload) => payload,
        Err(error) => {
            pending.clear();
            return socket
                .send(Message::Text(format!(r#"{{"error":"{error}"}}"#)))
                .await
                .is_ok();
        }
    };

    pending.clear();
    socket.send(Message::Binary(payload)).await.is_ok()
}

async fn stream_spectrum(
    mut socket: WebSocket,
    request: SpectrumSweepRequest,
    capture_control: Arc<CaptureControl>,
) {
    let target = request.sdr_id.clone();
    let _registration = capture_control.register(CaptureStreamType::Spectrum, target);
    let mut stop_rx = capture_control.subscribe_stop();
    let mut sweeps = spawn_hackrf_sweep(request);
    let mut pending = Vec::with_capacity(32);
    let mut flush_interval = tokio::time::interval(Duration::from_millis(200));
    flush_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            result = sweeps.recv() => {
                let Some(result) = result else {
                    let _ = send_spectrum_batch(&mut socket, &mut pending).await;
                    break;
                };

                match result {
                    Ok(sweep) => {
                        pending.push(sweep);
                        if pending.len() >= 32 && !send_spectrum_batch(&mut socket, &mut pending).await {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = send_spectrum_batch(&mut socket, &mut pending).await;
                        let _ = socket
                            .send(Message::Text(format!(r#"{{"error":"{error}"}}"#)))
                            .await;
                        break;
                    }
                }
            }
            _ = flush_interval.tick() => {
                if !send_spectrum_batch(&mut socket, &mut pending).await {
                    break;
                }
            }
            stop_result = stop_rx.changed() => {
                let _ = stop_result;
                let _ = send_spectrum_batch(&mut socket, &mut pending).await;
                let _ = socket
                    .send(Message::Text(r#"{"event":"capture_stopped"}"#.to_string()))
                    .await;
                break;
            }
            client_message = socket.recv() => {
                if client_message.is_none() {
                    break;
                }
            }
        }
    }
}

async fn send_spectrum_batch(socket: &mut WebSocket, pending: &mut Vec<SpectrumSweep>) -> bool {
    if pending.is_empty() {
        return true;
    }

    let payload = match crate::arrow_stream::encode_spectrum_sweeps_ipc(pending) {
        Ok(payload) => payload,
        Err(error) => {
            pending.clear();
            return socket
                .send(Message::Text(format!(r#"{{"error":"{error}"}}"#)))
                .await
                .is_ok();
        }
    };

    pending.clear();
    socket.send(Message::Binary(payload)).await.is_ok()
}

async fn stream_spectrum_summaries(
    mut socket: WebSocket,
    request: SpectrumSweepRequest,
    capture_control: Arc<CaptureControl>,
) {
    let target = format!("{}:summary", request.sdr_id);
    let _registration = capture_control.register(CaptureStreamType::Spectrum, target);
    let mut stop_rx = capture_control.subscribe_stop();
    let mut sweeps = spawn_hackrf_sweep(request);
    let mut last_capture_unix_nanos: Option<i64> = None;

    loop {
        tokio::select! {
            result = sweeps.recv() => {
                let Some(result) = result else {
                    break;
                };

                match result {
                    Ok(sweep) => {
                        let sweep_rate_hz = last_capture_unix_nanos
                            .and_then(|last| {
                                let delta = sweep.captured_at_unix_nanos.saturating_sub(last);
                                (delta > 0).then(|| 1_000_000_000.0_f32 / delta as f32)
                            })
                            .filter(|rate| rate.is_finite() && *rate > 0.0);
                        last_capture_unix_nanos = Some(sweep.captured_at_unix_nanos);
                        let summary = summarize_sweep(&sweep, sweep_rate_hz);
                        if !send_spectrum_summary(&mut socket, &summary).await {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = socket
                            .send(Message::Text(format!(r#"{{"error":"{error}"}}"#)))
                            .await;
                        break;
                    }
                }
            }
            stop_result = stop_rx.changed() => {
                let _ = stop_result;
                let _ = socket
                    .send(Message::Text(r#"{"event":"capture_stopped"}"#.to_string()))
                    .await;
                break;
            }
            client_message = socket.recv() => {
                if client_message.is_none() {
                    break;
                }
            }
        }
    }
}

async fn send_spectrum_summary(socket: &mut WebSocket, summary: &SpectrumSummary) -> bool {
    match serde_json::to_string(summary) {
        Ok(payload) => socket.send(Message::Text(payload)).await.is_ok(),
        Err(error) => {
            let payload = serde_json::json!({
                "error": error.to_string(),
            });
            socket
                .send(Message::Text(payload.to_string()))
                .await
                .is_ok()
        }
    }
}

fn internal_error(error: String) -> (StatusCode, Json<ErrorResponse>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ErrorResponse { error }),
    )
}

async fn require_auth(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    let actual = extract_bearer_token(headers)?;

    if setup_token_matches(state, actual) {
        return Ok(());
    }

    let runtime_config = load_runtime_config(state.config())
        .await
        .map_err(internal_error)?;
    let actual_hash = hash_token(actual);
    if runtime_config
        .paired_devices
        .iter()
        .any(|device| constant_time_eq(device.token_hash.as_bytes(), actual_hash.as_bytes()))
    {
        Ok(())
    } else {
        Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "invalid bearer token".to_string(),
            }),
        ))
    }
}

fn require_setup_auth(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    ensure_setup_token_configured(state)?;
    let actual = extract_bearer_token(headers)?;

    if setup_token_matches(state, actual) {
        Ok(())
    } else {
        Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "invalid setup token".to_string(),
            }),
        ))
    }
}

fn setup_token_matches(state: &AppState, actual: &str) -> bool {
    state
        .config
        .api_token
        .as_deref()
        .filter(|expected| !expected.is_empty())
        .is_some_and(|expected| constant_time_eq(expected.as_bytes(), actual.as_bytes()))
}

fn extract_bearer_token(headers: &HeaderMap) -> Result<&str, (StatusCode, Json<ErrorResponse>)> {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "missing bearer token".to_string(),
                }),
            )
        })
}

fn ensure_setup_token_configured(
    state: &AppState,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    if state
        .config
        .api_token
        .as_deref()
        .is_some_and(|token| !token.is_empty())
    {
        Ok(())
    } else {
        Err((
            StatusCode::FORBIDDEN,
            Json(ErrorResponse {
                error: "pairing is disabled until api_token is configured".to_string(),
            }),
        ))
    }
}

fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    hex_encode(&digest)
}

fn generate_pairing_token() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("failed to generate pairing token: {error}"))?;

    Ok(hex_encode(&bytes))
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

fn unix_secs_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn constant_time_eq(expected: &[u8], actual: &[u8]) -> bool {
    let mut diff = expected.len() ^ actual.len();
    let max_len = expected.len().max(actual.len());

    for idx in 0..max_len {
        let left = expected.get(idx).copied().unwrap_or_default();
        let right = actual.get(idx).copied().unwrap_or_default();
        diff |= usize::from(left ^ right);
    }

    diff == 0
}

fn default_sidekick_id() -> String {
    "fieldsurvey-sidekick".to_string()
}

fn default_radio_id() -> String {
    "radio-0".to_string()
}

fn default_hop_interval_ms() -> u64 {
    250
}

fn default_sdr_id() -> String {
    "hackrf-0".to_string()
}

fn default_spectrum_frequency_min_mhz() -> u32 {
    2400
}

fn default_spectrum_frequency_max_mhz() -> u32 {
    2500
}

fn default_spectrum_bin_width_hz() -> u32 {
    1_000_000
}

fn default_spectrum_lna_gain_db() -> u8 {
    8
}

fn default_spectrum_vga_gain_db() -> u8 {
    8
}

fn default_spectrum_sweep_count() -> u32 {
    1_000_000
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn status_response_uses_service_identity() {
        let temp = TempDir::new().unwrap();
        let cfg = SidekickConfig {
            sysfs_net_path: temp.path().to_path_buf(),
            ..SidekickConfig::default()
        };
        let state = AppState::new(cfg);
        let status = build_status_response(&state);

        assert_eq!(status.service, "serviceradar-fieldsurvey-sidekick");
        assert!(!status.capture_running);
    }

    #[test]
    fn builds_monitor_prepare_response() {
        let response = build_monitor_prepare_response(MonitorPrepareRequest {
            interface_name: "wlan1".to_string(),
            frequency_mhz: None,
            dry_run: false,
        })
        .unwrap();

        assert_eq!(response.plan.interface_name, "wlan1");
        assert_eq!(response.plan.commands.len(), 3);
    }

    #[test]
    fn builds_capture_request_from_query() {
        let request = build_capture_request(ObservationStreamQuery {
            interface_name: " wlan2 ".to_string(),
            sidekick_id: " sidekick-1 ".to_string(),
            radio_id: " radio-1 ".to_string(),
            frequencies_mhz: None,
            hop_interval_ms: 250,
        })
        .unwrap();

        assert_eq!(request.interface_name, "wlan2");
        assert_eq!(request.sidekick_id, "sidekick-1");
        assert_eq!(request.radio_id, "radio-1");
    }

    #[test]
    fn builds_observation_stream_request_with_channel_hop_plan() {
        let request = build_observation_stream_request(ObservationStreamQuery {
            interface_name: "wlan2".to_string(),
            sidekick_id: "sidekick-1".to_string(),
            radio_id: "radio-1".to_string(),
            frequencies_mhz: Some("5180,5200,5220".to_string()),
            hop_interval_ms: 300,
        })
        .unwrap();

        let channel_hop = request.channel_hop.unwrap();
        assert_eq!(request.capture.interface_name, "wlan2");
        assert_eq!(channel_hop.frequencies_mhz, vec![5_180, 5_200, 5_220]);
        assert_eq!(channel_hop.interval, Duration::from_millis(300));
    }

    #[test]
    fn builds_spectrum_sweep_request_from_query() {
        let request = build_spectrum_sweep_request(SpectrumStreamQuery {
            sidekick_id: " sidekick-1 ".to_string(),
            sdr_id: " hackrf-main ".to_string(),
            serial_number: Some(" serial-1 ".to_string()),
            frequency_min_mhz: 2400,
            frequency_max_mhz: 2484,
            bin_width_hz: 1_000_000,
            lna_gain_db: 8,
            vga_gain_db: 8,
            sweep_count: 1024,
        })
        .unwrap();

        assert_eq!(request.sidekick_id, "sidekick-1");
        assert_eq!(request.sdr_id, "hackrf-main");
        assert_eq!(request.serial_number.as_deref(), Some("serial-1"));
        assert_eq!(request.frequency_min_mhz, 2400);
    }

    #[test]
    fn constant_time_eq_checks_value_and_length() {
        assert!(constant_time_eq(b"secret", b"secret"));
        assert!(!constant_time_eq(b"secret", b"secRet"));
        assert!(!constant_time_eq(b"secret", b"secret2"));
    }

    #[test]
    fn token_hash_is_stable_and_hex_encoded() {
        let hash = hash_token("paired-token");

        assert_eq!(hash, hash_token("paired-token"));
        assert_eq!(hash.len(), 64);
        assert!(hash.chars().all(|ch| ch.is_ascii_hexdigit()));
    }

    #[tokio::test]
    async fn auth_accepts_setup_token_or_paired_device_token() {
        let temp = TempDir::new().unwrap();
        let cfg = SidekickConfig {
            state_dir: temp.path().to_path_buf(),
            api_token: Some("setup-token".to_string()),
            ..SidekickConfig::default()
        };
        let runtime_config = SidekickRuntimeConfig::default()
            .upsert_paired_device(
                "iphone-1".to_string(),
                Some("Survey Phone".to_string()),
                hash_token("paired-token"),
                1_777_132_800,
            )
            .unwrap();
        save_runtime_config(&cfg, &runtime_config).await.unwrap();
        let state = AppState::new(cfg);

        let mut setup_headers = HeaderMap::new();
        setup_headers.insert(
            axum::http::header::AUTHORIZATION,
            "Bearer setup-token".parse().unwrap(),
        );
        assert!(require_auth(&state, &setup_headers).await.is_ok());

        let mut paired_headers = HeaderMap::new();
        paired_headers.insert(
            axum::http::header::AUTHORIZATION,
            "Bearer paired-token".parse().unwrap(),
        );
        assert!(require_auth(&state, &paired_headers).await.is_ok());

        let mut bad_headers = HeaderMap::new();
        bad_headers.insert(
            axum::http::header::AUTHORIZATION,
            "Bearer wrong".parse().unwrap(),
        );
        assert!(require_auth(&state, &bad_headers).await.is_err());
    }

    #[tokio::test]
    async fn dry_run_prepare_does_not_execute_commands() {
        let response = prepare_monitor_response(MonitorPrepareRequest {
            interface_name: "wlan1".to_string(),
            frequency_mhz: Some(2_437),
            dry_run: true,
        })
        .await
        .unwrap();

        assert!(response.result.dry_run);
        assert!(response.result.executions.is_empty());
        assert_eq!(response.result.plan.commands.len(), 4);
    }
}
