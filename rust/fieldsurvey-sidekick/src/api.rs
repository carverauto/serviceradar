mod auth;
mod handlers;
mod models;
mod streams;

use crate::capture_control::CaptureControl;
use crate::config::SidekickConfig;
use axum::Router;
use axum::routing::{get, post};
use std::sync::Arc;

pub use handlers::{
    build_capture_request, build_monitor_prepare_response, build_observation_stream_request,
    build_spectrum_sweep_request, build_status_response, prepare_monitor_response,
};
pub use models::{
    CaptureStopResponse, ErrorResponse, HealthResponse, MonitorPrepareExecutionResponse,
    MonitorPrepareResponse, ObservationStreamQuery, ObservationStreamRequest, PairingClaimRequest,
    PairingClaimResponse, SpectrumStreamQuery, StatusResponse, WifiUplinkExecutionResponse,
    WifiUplinkPlanResponse,
};

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
        .route("/healthz", get(handlers::healthz))
        .route("/status", get(handlers::status))
        .route("/pairing/claim", post(handlers::pairing_claim))
        .route(
            "/config",
            get(handlers::get_config).put(handlers::put_config),
        )
        .route("/capture/stop", post(handlers::stop_capture))
        .route("/observations/stream", get(handlers::observation_stream))
        .route("/spectrum/stream", get(handlers::spectrum_stream))
        .route(
            "/spectrum/summary-stream",
            get(handlers::spectrum_summary_stream),
        )
        .route("/radios/monitor-plan", post(handlers::monitor_plan))
        .route("/radios/prepare-monitor", post(handlers::prepare_monitor))
        .route("/wifi/uplink-plan", post(handlers::wifi_uplink_plan))
        .route(
            "/wifi/configure-uplink",
            post(handlers::configure_wifi_uplink),
        )
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime_config::{SidekickRuntimeConfig, save_runtime_config};
    use axum::http::{HeaderMap, header};
    use std::time::Duration;
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
        let response = build_monitor_prepare_response(crate::radio::MonitorPrepareRequest {
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
        assert!(auth::constant_time_eq(b"secret", b"secret"));
        assert!(!auth::constant_time_eq(b"secret", b"secRet"));
        assert!(!auth::constant_time_eq(b"secret", b"secret2"));
    }

    #[test]
    fn token_hash_is_stable_and_hex_encoded() {
        let hash = auth::hash_token("paired-token");

        assert_eq!(hash, auth::hash_token("paired-token"));
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
                auth::hash_token("paired-token"),
                1_777_132_800,
            )
            .unwrap();
        save_runtime_config(&cfg, &runtime_config).await.unwrap();
        let state = AppState::new(cfg);

        let mut setup_headers = HeaderMap::new();
        setup_headers.insert(header::AUTHORIZATION, "Bearer setup-token".parse().unwrap());
        assert!(auth::require_auth(&state, &setup_headers).await.is_ok());

        let mut paired_headers = HeaderMap::new();
        paired_headers.insert(
            header::AUTHORIZATION,
            "Bearer paired-token".parse().unwrap(),
        );
        assert!(auth::require_auth(&state, &paired_headers).await.is_ok());

        let mut bad_headers = HeaderMap::new();
        bad_headers.insert(header::AUTHORIZATION, "Bearer wrong".parse().unwrap());
        assert!(auth::require_auth(&state, &bad_headers).await.is_err());
    }

    #[tokio::test]
    async fn dry_run_prepare_does_not_execute_commands() {
        let response = prepare_monitor_response(crate::radio::MonitorPrepareRequest {
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
