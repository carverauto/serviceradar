use super::AppState;
use super::auth::{
    generate_pairing_token, hash_token, internal_error, require_auth, require_setup_auth,
    unix_secs_now,
};
use super::models::{
    CaptureStopResponse, ChannelHopMode, ErrorResponse, HealthResponse,
    MonitorPrepareExecutionResponse, MonitorPrepareResponse, ObservationStreamQuery,
    ObservationStreamRequest, PairingClaimRequest, PairingClaimResponse, SpectrumStreamQuery,
    StatusResponse, WifiUplinkExecutionResponse, WifiUplinkPlanResponse,
};
use super::streams::{stream_observations, stream_spectrum, stream_spectrum_summaries};
use crate::adaptive_scan::build_adaptive_channel_hop_request;
use crate::live_capture::CaptureRequest;
use crate::radio::{
    MonitorPrepareRequest, RadioDiscovery, build_channel_hop_request, build_monitor_prepare_plan,
    execute_monitor_prepare_plan,
};
use crate::runtime_config::{
    RuntimeConfigUpdateRequest, SidekickRuntimeConfig, SidekickRuntimeConfigResponse,
    load_runtime_config, save_runtime_config,
};
use crate::spectrum::SpectrumSweepRequest;
use crate::wifi::{WifiUplinkRequest, build_wifi_uplink_plan, execute_wifi_uplink_plan};
use axum::Json;
use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;

pub(super) async fn healthz() -> Json<HealthResponse> {
    Json(HealthResponse { ok: true })
}

pub(super) async fn status(State(state): State<AppState>) -> Json<StatusResponse> {
    Json(build_status_response(&state))
}

pub(super) async fn get_config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<SidekickRuntimeConfigResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    load_runtime_config(state.config())
        .await
        .map(|config| Json(config.response()))
        .map_err(internal_error)
}

pub(super) async fn put_config(
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

pub(super) async fn pairing_claim(
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

pub(super) async fn stop_capture(
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

pub(super) async fn monitor_plan(
    Json(request): Json<MonitorPrepareRequest>,
) -> Result<Json<MonitorPrepareResponse>, (StatusCode, Json<ErrorResponse>)> {
    build_monitor_prepare_response(request)
        .map(Json)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))
}

pub(super) async fn prepare_monitor(
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

pub(super) async fn wifi_uplink_plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<WifiUplinkRequest>,
) -> Result<Json<WifiUplinkPlanResponse>, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    build_wifi_uplink_plan(&request)
        .map(|plan| Json(WifiUplinkPlanResponse { plan }))
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))
}

pub(super) async fn configure_wifi_uplink(
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

pub(super) async fn observation_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(mut query): Query<ObservationStreamQuery>,
    ws: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    if query.scan_mode.trim().eq_ignore_ascii_case("adaptive") && query.frequencies_mhz.is_none() {
        query.frequencies_mhz = adaptive_fallback_frequencies(&state, &query.interface_name);
    }
    let request = build_observation_stream_request(query)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    let capture_control = state.capture_control();
    let adaptive_scan = state.adaptive_scan();

    Ok(ws.on_upgrade(move |socket| {
        stream_observations(socket, request, capture_control, adaptive_scan)
    }))
}

pub(super) async fn spectrum_stream(
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

pub(super) async fn spectrum_summary_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SpectrumStreamQuery>,
    ws: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    require_auth(&state, &headers).await?;
    let request = build_spectrum_sweep_request(query)
        .map_err(|error| (StatusCode::BAD_REQUEST, Json(ErrorResponse { error })))?;
    let capture_control = state.capture_control();
    let adaptive_scan = state.adaptive_scan();

    Ok(ws.on_upgrade(move |socket| {
        stream_spectrum_summaries(socket, request, capture_control, adaptive_scan)
    }))
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

fn adaptive_fallback_frequencies(state: &AppState, interface_name: &str) -> Option<String> {
    let interface = interface_name.trim();
    if interface.is_empty() {
        return None;
    }

    let inventory = RadioDiscovery::new(
        state.config.sysfs_net_path.clone(),
        state.config.interfaces.clone(),
    )
    .discover();
    let mut frequencies = inventory
        .radios
        .into_iter()
        .find(|radio| radio.name == interface)
        .map(|radio| radio.supported_frequencies_mhz)
        .unwrap_or_default();

    frequencies.retain(|frequency| (2_412..=7_125).contains(frequency));
    frequencies.sort_unstable();
    frequencies.dedup();

    (!frequencies.is_empty()).then(|| {
        frequencies
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(",")
    })
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

    let scan_mode = query.scan_mode.trim().to_ascii_lowercase();
    let channel_hop = match query.frequencies_mhz {
        Some(raw_frequencies) if scan_mode == "adaptive" => build_adaptive_channel_hop_request(
            interface_name,
            &raw_frequencies,
            query.hop_interval_ms,
        )?
        .map(ChannelHopMode::Adaptive),
        Some(raw_frequencies) => {
            build_channel_hop_request(interface_name, &raw_frequencies, query.hop_interval_ms)?
                .map(ChannelHopMode::Fixed)
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
