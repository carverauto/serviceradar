//! Configuration types and CLI/environment parsing for `serviceradar-media-worker`.

use crate::backend::{InferenceBackendKind, InferenceDevicePreference, InferencePrecision};
use crate::credentials::WorkerAuthCredentials;
use crate::errors::CapabilityError;
use crate::tracking::TrackerMode;
use clap::Parser;
use core::fmt::{self, Display, Formatter};
use core::str::FromStr;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

pub const DEFAULT_VANTAGE_VLM_URL: &str = "http://serviceradar-camera-vlm:8080/v1/chat/completions";
pub const DEFAULT_VANTAGE_VLM_MODEL: &str = "qwen3.5-4b";
pub const DEFAULT_VANTAGE_CONSUMER_NAME: &str = "camera_vantage_vlm_worker_v1";
pub const DEFAULT_VANTAGE_WORKER_ID: &str = "serviceradar-media-worker";

/// Zeroizing API key wrapper whose `Debug` output is always redacted.
#[derive(Clone, PartialEq, Eq)]
pub struct RedactedVlmApiKey(Zeroizing<String>);

impl RedactedVlmApiKey {
    pub fn new(raw: impl Into<String>) -> Self {
        Self(Zeroizing::new(raw.into()))
    }

    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    pub fn to_zeroizing(&self) -> Zeroizing<String> {
        self.0.clone()
    }
}

impl fmt::Debug for RedactedVlmApiKey {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str("[REDACTED]")
    }
}

/// Normalizes an OpenAI-compatible VLM URL to its `/v1/chat/completions` endpoint.
pub fn normalize_vlm_url(raw: &str) -> Result<String, CapabilityError> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() || (!trimmed.starts_with("http://") && !trimmed.starts_with("https://")) {
        return Err(CapabilityError::invalid_configuration(format!(
            "invalid vantage_vlm_url '{raw}': expected http:// or https:// URL"
        )));
    }
    if trimmed.ends_with("/chat/completions") {
        Ok(trimmed.to_string())
    } else if trimmed.ends_with("/v1") {
        Ok(format!("{trimmed}/chat/completions"))
    } else {
        Ok(format!("{trimmed}/v1/chat/completions"))
    }
}

/// Execution provider configuration (`design.md` Section 1.3).
///
/// `Cuda` requires verified GPU hardware and runtime availability with zero
/// silent CPU fallback. `Tensorrt` is parsed so startup admission fails closed
/// rather than falling back to CPU.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionProvider {
    Tensorrt,
    Cuda,
    CpuExplicit,
}

impl ExecutionProvider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Tensorrt => "tensorrt",
            Self::Cuda => "cuda",
            Self::CpuExplicit => "cpu_explicit",
        }
    }

    pub fn requires_gpu(self) -> bool {
        matches!(self, Self::Tensorrt | Self::Cuda)
    }
}

impl Display for ExecutionProvider {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for ExecutionProvider {
    type Err = CapabilityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "tensorrt" => Ok(Self::Tensorrt),
            "cuda" => Ok(Self::Cuda),
            "cpu_explicit" => Ok(Self::CpuExplicit),
            other => Err(CapabilityError::invalid_configuration(format!(
                "unsupported execution_provider '{other}'; expected 'cuda' or 'cpu_explicit'"
            ))),
        }
    }
}

/// Observed or declared GPU sharing mode (`cloud-control-plane.md` C3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GpuSharingMode {
    Physical,
    Mig,
    TimeSliced,
    CpuExplicit,
}

impl GpuSharingMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Physical => "physical",
            Self::Mig => "mig",
            Self::TimeSliced => "time_sliced",
            Self::CpuExplicit => "cpu_explicit",
        }
    }

    /// Maximum Stage 2 vision-tower batch size permitted for this sharing mode.
    /// Time-sliced GPU shares have no hardware VRAM isolation, so batch size is capped.
    pub fn max_stage2_batch_size(self) -> usize {
        match self {
            Self::Physical | Self::Mig => 16,
            Self::TimeSliced => 4,
            Self::CpuExplicit => 8,
        }
    }
}

impl Display for GpuSharingMode {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for GpuSharingMode {
    type Err = CapabilityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "physical" => Ok(Self::Physical),
            "mig" => Ok(Self::Mig),
            "time_sliced" => Ok(Self::TimeSliced),
            "cpu_explicit" => Ok(Self::CpuExplicit),
            other => Err(CapabilityError::invalid_configuration(format!(
                "unsupported gpu_sharing_mode '{other}'; expected 'physical', 'mig', 'time_sliced', or 'cpu_explicit'"
            ))),
        }
    }
}

/// Default NATS inbox prefix for the worker's own request replies, pull
/// deliveries and publish acknowledgements. A dedicated prefix lets the broker
/// grant the worker `_INBOX.media-worker.>` instead of the account-wide
/// `_INBOX.>`, which also carries other services' JetStream deliveries.
pub const DEFAULT_NATS_INBOX_PREFIX: &str = "_INBOX.media-worker";

/// Pinned model identity and SHA-256 artifact configuration (`2.2`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelPinConfig {
    detector_model_id: String,
    detector_model_version: String,
    detector_path: Option<PathBuf>,
    detector_sha256: Option<String>,
    embedder_model_id: String,
    embedder_model_version: String,
    embedding_dim: usize,
    embedder_path: Option<PathBuf>,
    embedder_sha256: Option<String>,
    text_path: Option<PathBuf>,
    text_sha256: Option<String>,
}

impl Default for ModelPinConfig {
    fn default() -> Self {
        Self {
            detector_model_id: "yolox-s".to_string(),
            detector_model_version: "2026.1".to_string(),
            detector_path: None,
            detector_sha256: None,
            embedder_model_id: "siglip-b16-384".to_string(),
            embedder_model_version: "2026.1".to_string(),
            embedding_dim: 768,
            embedder_path: None,
            embedder_sha256: None,
            text_path: None,
            text_sha256: None,
        }
    }
}

impl ModelPinConfig {
    pub fn new(
        detector_model_id: impl Into<String>,
        detector_model_version: impl Into<String>,
        embedder_model_id: impl Into<String>,
        embedder_model_version: impl Into<String>,
        embedding_dim: usize,
    ) -> Self {
        Self {
            detector_model_id: detector_model_id.into(),
            detector_model_version: detector_model_version.into(),
            detector_path: None,
            detector_sha256: None,
            embedder_model_id: embedder_model_id.into(),
            embedder_model_version: embedder_model_version.into(),
            embedding_dim,
            embedder_path: None,
            embedder_sha256: None,
            text_path: None,
            text_sha256: None,
        }
    }

    pub fn with_detector_pin(mut self, path: PathBuf, sha256: impl Into<String>) -> Self {
        self.detector_path = Some(path);
        self.detector_sha256 = Some(sha256.into());
        self
    }

    pub fn with_embedder_pin(mut self, path: PathBuf, sha256: impl Into<String>) -> Self {
        self.embedder_path = Some(path);
        self.embedder_sha256 = Some(sha256.into());
        self
    }

    pub fn with_text_pin(mut self, path: PathBuf, sha256: impl Into<String>) -> Self {
        self.text_path = Some(path);
        self.text_sha256 = Some(sha256.into());
        self
    }

    pub fn set_detector_path(&mut self, path: Option<PathBuf>) {
        self.detector_path = path;
    }

    pub fn set_detector_sha256(&mut self, sha256: Option<String>) {
        self.detector_sha256 = sha256;
    }

    pub fn set_embedder_path(&mut self, path: Option<PathBuf>) {
        self.embedder_path = path;
    }

    pub fn set_embedder_sha256(&mut self, sha256: Option<String>) {
        self.embedder_sha256 = sha256;
    }

    pub fn set_text_path(&mut self, path: Option<PathBuf>) {
        self.text_path = path;
    }

    pub fn set_text_sha256(&mut self, sha256: Option<String>) {
        self.text_sha256 = sha256;
    }

    pub fn detector_model_id(&self) -> &str {
        &self.detector_model_id
    }

    pub fn detector_model_version(&self) -> &str {
        &self.detector_model_version
    }

    pub fn detector_path(&self) -> Option<&Path> {
        self.detector_path.as_deref()
    }

    pub fn detector_sha256(&self) -> Option<&str> {
        self.detector_sha256.as_deref()
    }

    pub fn embedder_model_id(&self) -> &str {
        &self.embedder_model_id
    }

    pub fn embedder_model_version(&self) -> &str {
        &self.embedder_model_version
    }

    pub fn embedding_dim(&self) -> usize {
        self.embedding_dim
    }

    pub fn embedder_path(&self) -> Option<&Path> {
        self.embedder_path.as_deref()
    }

    pub fn embedder_sha256(&self) -> Option<&str> {
        self.embedder_sha256.as_deref()
    }

    pub fn text_path(&self) -> Option<&Path> {
        self.text_path.as_deref()
    }

    pub fn text_sha256(&self) -> Option<&str> {
        self.text_sha256.as_deref()
    }
}

/// Runtime configuration for `serviceradar-media-worker`.
#[derive(Debug, Clone)]
pub struct WorkerConfig {
    listen_addr: SocketAddr,
    backend_kind: InferenceBackendKind,
    model_dir: Option<PathBuf>,
    device_preference: InferenceDevicePreference,
    precision: InferencePrecision,
    execution_provider: ExecutionProvider,
    declared_gpu_sharing_mode: Option<GpuSharingMode>,
    min_gpu_vram_mb: u64,
    ort_dylib_path: Option<PathBuf>,
    index_concurrency: usize,
    text_embed_concurrency: usize,
    skip_unchanged_empty_scenes: bool,
    tracker_mode: TrackerMode,
    dedup_track_crops: bool,
    models: ModelPinConfig,
    control_plane_url: String,
    worker_auth: Option<WorkerAuthCredentials>,
    nvr_scheme: String,
    nvr_read_port: u16,
    nvr_host_suffix: Option<String>,
    nvr_tls_ca_file: Option<PathBuf>,
    nvr_tls_cert_file: Option<PathBuf>,
    nvr_tls_key_file: Option<PathBuf>,
    nvr_auth_token_file: Option<PathBuf>,
    nats_url: String,
    nats_creds_file: Option<PathBuf>,
    nats_tls_ca_file: Option<PathBuf>,
    nats_tls_cert_file: Option<PathBuf>,
    nats_tls_key_file: Option<PathBuf>,
    nats_cert_policy_file: Option<PathBuf>,
    nats_domain: Option<String>,
    nats_inbox_prefix: String,
    jobs_stream_name: String,
    results_stream_name: String,
    consumer_name: String,
    otel_endpoint: String,
    vantage_vlm_enabled: bool,
    vantage_vlm_url: Option<String>,
    vantage_vlm_model: String,
    vantage_vlm_api_key: Option<RedactedVlmApiKey>,
    vantage_vlm_timeout_ms: u64,
    vantage_vlm_concurrency: usize,
    vantage_consumer_name: String,
    worker_id: String,
}

impl Default for WorkerConfig {
    fn default() -> Self {
        Self {
            listen_addr: SocketAddr::from(([0, 0, 0, 0], 8096)),
            backend_kind: InferenceBackendKind::Candle,
            model_dir: None,
            device_preference: InferenceDevicePreference::Auto,
            precision: InferencePrecision::Auto,
            execution_provider: ExecutionProvider::Cuda,
            declared_gpu_sharing_mode: None,
            min_gpu_vram_mb: 1024,
            ort_dylib_path: None,
            index_concurrency: 2,
            text_embed_concurrency: 4,
            skip_unchanged_empty_scenes: true,
            tracker_mode: TrackerMode::ByteTrack,
            dedup_track_crops: true,
            models: ModelPinConfig::default(),
            control_plane_url: "http://serviceradar-web-ng:4001".to_string(),
            worker_auth: None,
            nvr_scheme: "http".to_string(),
            nvr_read_port: 8444,
            nvr_host_suffix: None,
            nvr_tls_ca_file: None,
            nvr_tls_cert_file: None,
            nvr_tls_key_file: None,
            nvr_auth_token_file: None,
            nats_url: "nats://serviceradar-nats:4222".to_string(),
            nats_creds_file: None,
            nats_tls_ca_file: None,
            nats_tls_cert_file: None,
            nats_tls_key_file: None,
            nats_cert_policy_file: None,
            nats_domain: None,
            nats_inbox_prefix: DEFAULT_NATS_INBOX_PREFIX.to_string(),
            jobs_stream_name: "CAMERA_MEDIA_JOBS".to_string(),
            results_stream_name: "CAMERA_MEDIA_RESULTS".to_string(),
            consumer_name: "camera_visual_index_worker_v1".to_string(),
            otel_endpoint: "http://serviceradar-otel:4317".to_string(),
            vantage_vlm_enabled: false,
            vantage_vlm_url: None,
            vantage_vlm_model: DEFAULT_VANTAGE_VLM_MODEL.to_string(),
            vantage_vlm_api_key: None,
            vantage_vlm_timeout_ms: 30_000,
            vantage_vlm_concurrency: 2,
            vantage_consumer_name: DEFAULT_VANTAGE_CONSUMER_NAME.to_string(),
            worker_id: DEFAULT_VANTAGE_WORKER_ID.to_string(),
        }
    }
}

impl WorkerConfig {
    pub fn cpu_explicit_default() -> Self {
        Self {
            execution_provider: ExecutionProvider::CpuExplicit,
            index_concurrency: 1,
            text_embed_concurrency: 4,
            ..Self::default()
        }
    }

    pub fn with_listen_addr(mut self, addr: SocketAddr) -> Self {
        self.listen_addr = addr;
        self
    }

    pub fn with_backend_kind(mut self, kind: InferenceBackendKind) -> Self {
        self.backend_kind = kind;
        self
    }

    pub fn with_model_dir(mut self, dir: Option<PathBuf>) -> Self {
        self.model_dir = dir;
        self
    }

    pub fn with_device_preference(mut self, pref: InferenceDevicePreference) -> Self {
        self.device_preference = pref;
        self
    }

    pub fn with_execution_provider(mut self, provider: ExecutionProvider) -> Self {
        self.execution_provider = provider;
        self
    }

    pub fn with_declared_gpu_sharing_mode(mut self, mode: Option<GpuSharingMode>) -> Self {
        self.declared_gpu_sharing_mode = mode;
        self
    }

    pub fn with_min_gpu_vram_mb(mut self, mb: u64) -> Self {
        self.min_gpu_vram_mb = mb;
        self
    }

    pub fn with_ort_dylib_path(mut self, path: Option<PathBuf>) -> Self {
        self.ort_dylib_path = path;
        self
    }

    pub fn with_concurrency(mut self, index_jobs: usize, text_embeds: usize) -> Self {
        self.index_concurrency = index_jobs;
        self.text_embed_concurrency = text_embeds;
        self
    }

    pub fn with_skip_unchanged_empty_scenes(mut self, skip: bool) -> Self {
        self.skip_unchanged_empty_scenes = skip;
        self
    }

    pub fn with_tracker_mode(mut self, mode: TrackerMode) -> Self {
        self.tracker_mode = mode;
        self
    }

    pub fn with_dedup_track_crops(mut self, dedup: bool) -> Self {
        self.dedup_track_crops = dedup;
        self
    }

    pub fn with_models(mut self, models: ModelPinConfig) -> Self {
        self.models = models;
        self
    }

    pub fn with_control_plane(
        mut self,
        control_plane_url: impl Into<String>,
        auth: Option<WorkerAuthCredentials>,
    ) -> Self {
        self.control_plane_url = control_plane_url.into();
        self.worker_auth = auth;
        self
    }

    pub fn with_nvr_read(mut self, scheme: impl Into<String>, port: u16) -> Self {
        self.nvr_scheme = scheme.into();
        self.nvr_read_port = port;
        self
    }

    pub fn with_nats_url(mut self, url: impl Into<String>) -> Self {
        self.nats_url = url.into();
        self
    }

    pub fn with_otel_endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.otel_endpoint = endpoint.into();
        self
    }

    pub fn with_vantage_vlm(
        mut self,
        enabled: bool,
        url: Option<String>,
        model: impl Into<String>,
    ) -> Self {
        self.vantage_vlm_enabled = enabled;
        self.vantage_vlm_url = url;
        self.vantage_vlm_model = model.into();
        self
    }

    pub fn with_vantage_vlm_api_key(mut self, key: Option<String>) -> Self {
        self.vantage_vlm_api_key = key.map(RedactedVlmApiKey::new);
        self
    }

    pub fn with_vantage_vlm_timeout_ms(mut self, timeout_ms: u64) -> Self {
        self.vantage_vlm_timeout_ms = timeout_ms.clamp(1_000, 120_000);
        self
    }

    pub fn with_vantage_vlm_concurrency(mut self, concurrency: usize) -> Self {
        self.vantage_vlm_concurrency = concurrency.clamp(1, 16);
        self
    }

    pub fn with_vantage_consumer_name(mut self, name: impl Into<String>) -> Self {
        self.vantage_consumer_name = name.into();
        self
    }

    pub fn with_worker_id(mut self, id: impl Into<String>) -> Self {
        self.worker_id = id.into();
        self
    }

    pub fn listen_addr(&self) -> SocketAddr {
        self.listen_addr
    }

    pub fn backend_kind(&self) -> InferenceBackendKind {
        self.backend_kind
    }

    pub fn model_dir(&self) -> Option<&Path> {
        self.model_dir.as_deref()
    }

    pub fn device_preference(&self) -> InferenceDevicePreference {
        self.device_preference
    }

    pub fn precision(&self) -> InferencePrecision {
        self.precision
    }

    pub fn execution_provider(&self) -> ExecutionProvider {
        self.execution_provider
    }

    pub fn declared_gpu_sharing_mode(&self) -> Option<GpuSharingMode> {
        self.declared_gpu_sharing_mode
    }

    pub fn min_gpu_vram_mb(&self) -> u64 {
        self.min_gpu_vram_mb
    }

    pub fn ort_dylib_path(&self) -> Option<&Path> {
        self.ort_dylib_path.as_deref()
    }

    pub fn index_concurrency(&self) -> usize {
        self.index_concurrency
    }

    pub fn text_embed_concurrency(&self) -> usize {
        self.text_embed_concurrency
    }

    pub fn skip_unchanged_empty_scenes(&self) -> bool {
        self.skip_unchanged_empty_scenes
    }

    pub fn tracker_mode(&self) -> TrackerMode {
        self.tracker_mode
    }

    pub fn dedup_track_crops(&self) -> bool {
        self.dedup_track_crops
    }

    pub fn models(&self) -> &ModelPinConfig {
        &self.models
    }

    pub fn control_plane_url(&self) -> &str {
        &self.control_plane_url
    }

    pub fn worker_auth(&self) -> Option<&WorkerAuthCredentials> {
        self.worker_auth.as_ref()
    }

    pub fn nvr_scheme(&self) -> &str {
        &self.nvr_scheme
    }

    pub fn nvr_read_port(&self) -> u16 {
        self.nvr_read_port
    }

    pub fn nvr_host_suffix(&self) -> Option<&str> {
        self.nvr_host_suffix.as_deref()
    }

    pub fn nvr_tls_ca_file(&self) -> Option<&Path> {
        self.nvr_tls_ca_file.as_deref()
    }

    pub fn nvr_tls_cert_file(&self) -> Option<&Path> {
        self.nvr_tls_cert_file.as_deref()
    }

    pub fn nvr_tls_key_file(&self) -> Option<&Path> {
        self.nvr_tls_key_file.as_deref()
    }

    pub fn nvr_auth_token_file(&self) -> Option<&Path> {
        self.nvr_auth_token_file.as_deref()
    }

    pub fn nats_url(&self) -> &str {
        &self.nats_url
    }

    pub fn nats_creds_file(&self) -> Option<&Path> {
        self.nats_creds_file.as_deref()
    }

    pub fn nats_tls_ca_file(&self) -> Option<&Path> {
        self.nats_tls_ca_file.as_deref()
    }

    pub fn nats_tls_cert_file(&self) -> Option<&Path> {
        self.nats_tls_cert_file.as_deref()
    }

    pub fn nats_tls_key_file(&self) -> Option<&Path> {
        self.nats_tls_key_file.as_deref()
    }

    pub fn nats_cert_policy_file(&self) -> Option<&Path> {
        self.nats_cert_policy_file.as_deref()
    }

    pub fn nats_domain(&self) -> Option<&str> {
        self.nats_domain.as_deref()
    }

    pub fn nats_inbox_prefix(&self) -> &str {
        &self.nats_inbox_prefix
    }

    pub fn jobs_stream_name(&self) -> &str {
        &self.jobs_stream_name
    }

    pub fn results_stream_name(&self) -> &str {
        &self.results_stream_name
    }

    pub fn consumer_name(&self) -> &str {
        &self.consumer_name
    }

    pub fn otel_endpoint(&self) -> &str {
        &self.otel_endpoint
    }

    pub fn vantage_vlm_enabled(&self) -> bool {
        self.vantage_vlm_enabled
    }

    pub fn vantage_vlm_url(&self) -> Option<&str> {
        self.vantage_vlm_url.as_deref()
    }

    pub fn resolved_vantage_vlm_url(&self) -> Result<String, CapabilityError> {
        let raw = self
            .vantage_vlm_url
            .as_deref()
            .unwrap_or(DEFAULT_VANTAGE_VLM_URL);
        normalize_vlm_url(raw)
    }

    pub fn vantage_vlm_model(&self) -> &str {
        &self.vantage_vlm_model
    }

    pub fn vantage_vlm_api_key(&self) -> Option<&RedactedVlmApiKey> {
        self.vantage_vlm_api_key.as_ref()
    }

    pub fn vantage_vlm_timeout_ms(&self) -> u64 {
        self.vantage_vlm_timeout_ms
    }

    pub fn vantage_vlm_concurrency(&self) -> usize {
        self.vantage_vlm_concurrency
    }

    pub fn vantage_consumer_name(&self) -> &str {
        &self.vantage_consumer_name
    }

    pub fn worker_id(&self) -> &str {
        &self.worker_id
    }
}

/// Command-line and environment arguments for `serviceradar-media-worker`.
#[derive(Parser, Debug, Clone)]
#[command(name = "serviceradar-media-worker")]
#[command(about = "Standalone stateless GPU media worker for NVR semantic clip search")]
pub struct CliArgs {
    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_LISTEN_ADDR")]
    listen_addr: Option<String>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_PORT", default_value_t = 8096)]
    port: u16,

    #[arg(long, env = "MEDIA_WORKER_BACKEND", default_value = "candle")]
    backend: InferenceBackendKind,

    #[arg(long, env = "MEDIA_WORKER_MODEL_DIR")]
    model_dir: Option<PathBuf>,

    #[arg(long, env = "MEDIA_WORKER_DEVICE", default_value = "auto")]
    device: String,

    /// SigLIP compute precision: `auto` (f16 on CUDA, f32 on CPU), `f32`, or `f16`.
    #[arg(long, env = "MEDIA_WORKER_DTYPE", default_value = "auto")]
    dtype: String,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_EXECUTION_PROVIDER")]
    execution_provider: Option<String>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_EXECUTION_BACKEND")]
    execution_backend: Option<String>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_GPU_SHARING_MODE")]
    gpu_sharing_mode: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_MIN_GPU_VRAM_MB",
        default_value_t = 1024
    )]
    min_gpu_vram_mb: u64,

    #[arg(long, env = "ORT_DYLIB_PATH")]
    ort_dylib_path: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_INDEX_CONCURRENCY")]
    index_concurrency: Option<usize>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_TEXT_EMBED_CONCURRENCY",
        default_value_t = 4
    )]
    text_embed_concurrency: usize,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_SKIP_UNCHANGED_EMPTY_SCENES",
        default_value_t = true
    )]
    skip_unchanged_empty_scenes: bool,

    #[arg(long, env = "MEDIA_WORKER_TRACKER", default_value = "bytetrack")]
    tracker: String,

    #[arg(
        long,
        env = "MEDIA_WORKER_DEDUP_TRACK_CROPS",
        default_value_t = true,
        action = clap::ArgAction::Set
    )]
    dedup_track_crops: bool,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_DETECTOR_MODEL_ID",
        default_value = "yolox-s"
    )]
    detector_model_id: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_DETECTOR_MODEL_VERSION",
        default_value = "2026.1"
    )]
    detector_model_version: String,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_DETECTOR_PATH")]
    detector_path: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_DETECTOR_SHA256")]
    detector_sha256: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_EMBEDDER_MODEL_ID",
        default_value = "siglip-b16-384"
    )]
    embedder_model_id: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_EMBEDDER_MODEL_VERSION",
        default_value = "2026.1"
    )]
    embedder_model_version: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_EMBEDDING_DIM",
        default_value_t = 768
    )]
    embedding_dim: usize,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_EMBEDDER_PATH")]
    embedder_path: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_EMBEDDER_SHA256")]
    embedder_sha256: Option<String>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_TEXT_PATH")]
    text_path: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_TEXT_SHA256")]
    text_sha256: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_CONTROL_PLANE_URL",
        default_value = "http://serviceradar-web-ng:4001"
    )]
    control_plane_url: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_AUTH_TOKEN",
        hide_env_values = true
    )]
    auth_token: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_TOKEN",
        hide_env_values = true
    )]
    fallback_auth_token: Option<String>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_DEPLOYMENT_REF")]
    deployment_ref: Option<String>,

    #[arg(long, env = "SERVICERADAR_CONTROL_PLANE_DEPLOYMENT_REF")]
    fallback_deployment_ref: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_GENERATION",
        default_value = "1"
    )]
    generation: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_NVR_SCHEME",
        default_value = "http"
    )]
    nvr_scheme: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_NVR_READ_PORT",
        default_value_t = 8444
    )]
    nvr_read_port: u16,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NVR_HOST_SUFFIX")]
    nvr_host_suffix: Option<String>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NVR_TLS_CA_FILE")]
    nvr_tls_ca_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NVR_TLS_CERT_FILE")]
    nvr_tls_cert_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NVR_TLS_KEY_FILE")]
    nvr_tls_key_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NVR_AUTH_TOKEN_FILE")]
    nvr_auth_token_file: Option<PathBuf>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_NATS_URL",
        default_value = "nats://serviceradar-nats:4222"
    )]
    nats_url: String,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NATS_CREDS_FILE")]
    nats_creds_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NATS_TLS_CA_FILE")]
    nats_tls_ca_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NATS_TLS_CERT_FILE")]
    nats_tls_cert_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NATS_TLS_KEY_FILE")]
    nats_tls_key_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NATS_CERT_POLICY_FILE")]
    nats_cert_policy_file: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_NATS_DOMAIN")]
    nats_domain: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_NATS_INBOX_PREFIX",
        default_value = DEFAULT_NATS_INBOX_PREFIX
    )]
    nats_inbox_prefix: String,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_OTEL_ENDPOINT",
        default_value = "http://serviceradar-otel:4317"
    )]
    otel_endpoint: String,

    #[arg(
        long,
        env = "SERVICERADAR_CAMERA_VLM_ENABLED",
        default_value_t = false,
        action = clap::ArgAction::Set
    )]
    vantage_vlm_enabled: bool,

    #[arg(long, env = "SERVICERADAR_CAMERA_VLM_URL")]
    vantage_vlm_url: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_CAMERA_VLM_MODEL",
        default_value = DEFAULT_VANTAGE_VLM_MODEL
    )]
    vantage_vlm_model: String,

    #[arg(long, env = "SERVICERADAR_CAMERA_VLM_API_KEY", hide_env_values = true)]
    vantage_vlm_api_key: Option<String>,

    #[arg(
        long,
        env = "SERVICERADAR_CAMERA_VLM_TIMEOUT_MS",
        default_value_t = 30_000
    )]
    vantage_vlm_timeout_ms: u64,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_VANTAGE_VLM_CONCURRENCY",
        default_value_t = 2
    )]
    vantage_vlm_concurrency: usize,

    #[arg(
        long,
        env = "SERVICERADAR_MEDIA_WORKER_VANTAGE_CONSUMER_NAME",
        default_value = DEFAULT_VANTAGE_CONSUMER_NAME
    )]
    vantage_consumer_name: String,

    #[arg(long, env = "SERVICERADAR_MEDIA_WORKER_ID")]
    worker_id: Option<String>,
}

impl CliArgs {
    pub fn into_worker_config(self) -> Result<WorkerConfig, CapabilityError> {
        let listen_addr = match self.listen_addr.as_deref().map(str::trim) {
            Some(addr) if !addr.is_empty() => addr.parse::<SocketAddr>().map_err(|err| {
                CapabilityError::invalid_configuration(format!(
                    "invalid listen_addr '{addr}': {err}"
                ))
            })?,
            _ => SocketAddr::from(([0, 0, 0, 0], self.port)),
        };

        let device_preference = InferenceDevicePreference::from_str(&self.device)?;
        let precision = InferencePrecision::from_str(&self.dtype)?;
        let tracker_mode = TrackerMode::from_str(&self.tracker)
            .map_err(|err| CapabilityError::invalid_configuration(err.to_string()))?;

        let raw_provider = self
            .execution_provider
            .as_deref()
            .or(self.execution_backend.as_deref())
            .unwrap_or("cuda");
        let execution_provider = ExecutionProvider::from_str(raw_provider)?;
        device_preference.validate_provider(execution_provider.requires_gpu())?;

        let model_dir = non_empty_path(self.model_dir);
        let declared_gpu_sharing_mode = match self
            .gpu_sharing_mode
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
        {
            Some(raw) => Some(GpuSharingMode::from_str(raw)?),
            None => None,
        };

        let default_index_conc = match execution_provider {
            ExecutionProvider::CpuExplicit => 1,
            ExecutionProvider::Cuda | ExecutionProvider::Tensorrt => 2,
        };
        let index_concurrency = self.index_concurrency.unwrap_or(default_index_conc);

        let mut models = ModelPinConfig::new(
            self.detector_model_id,
            self.detector_model_version,
            self.embedder_model_id,
            self.embedder_model_version,
            self.embedding_dim,
        );
        models.set_detector_path(non_empty_path(self.detector_path));
        models.set_detector_sha256(non_empty_opt(self.detector_sha256));
        models.set_embedder_path(non_empty_path(self.embedder_path));
        models.set_embedder_sha256(non_empty_opt(self.embedder_sha256));
        models.set_text_path(non_empty_path(self.text_path));
        models.set_text_sha256(non_empty_opt(self.text_sha256));

        let nats_inbox_prefix = validate_nats_inbox_prefix(&self.nats_inbox_prefix)?;

        let token =
            non_empty_opt(self.auth_token).or_else(|| non_empty_opt(self.fallback_auth_token));
        let dep_ref = non_empty_opt(self.deployment_ref)
            .or_else(|| non_empty_opt(self.fallback_deployment_ref));
        let worker_auth = match (token, dep_ref) {
            (Some(tok), Some(dep)) => Some(WorkerAuthCredentials::new(tok, dep, self.generation)),
            _ => None,
        };

        let vantage_vlm_url = match non_empty_opt(self.vantage_vlm_url) {
            Some(raw) => Some(normalize_vlm_url(&raw)?),
            None if self.vantage_vlm_enabled => Some(normalize_vlm_url(DEFAULT_VANTAGE_VLM_URL)?),
            None => None,
        };
        if !(1..=16).contains(&self.vantage_vlm_concurrency) {
            return Err(CapabilityError::invalid_configuration(format!(
                "vantage_vlm_concurrency {} must be in 1..=16",
                self.vantage_vlm_concurrency
            )));
        }
        let vantage_vlm_timeout_ms = self.vantage_vlm_timeout_ms.clamp(1_000, 120_000);
        let vantage_vlm_model = non_empty_opt(Some(self.vantage_vlm_model))
            .unwrap_or_else(|| DEFAULT_VANTAGE_VLM_MODEL.to_string());
        let vantage_consumer_name = non_empty_opt(Some(self.vantage_consumer_name))
            .unwrap_or_else(|| DEFAULT_VANTAGE_CONSUMER_NAME.to_string());
        let worker_id = non_empty_opt(self.worker_id)
            .or_else(|| non_empty_opt(std::env::var("HOSTNAME").ok()))
            .unwrap_or_else(|| DEFAULT_VANTAGE_WORKER_ID.to_string());
        let vantage_vlm_api_key =
            non_empty_opt(self.vantage_vlm_api_key).map(RedactedVlmApiKey::new);

        Ok(WorkerConfig {
            listen_addr,
            backend_kind: self.backend,
            model_dir,
            device_preference,
            precision,
            execution_provider,
            declared_gpu_sharing_mode,
            min_gpu_vram_mb: self.min_gpu_vram_mb,
            ort_dylib_path: non_empty_path(self.ort_dylib_path),
            index_concurrency,
            text_embed_concurrency: self.text_embed_concurrency,
            skip_unchanged_empty_scenes: self.skip_unchanged_empty_scenes,
            tracker_mode,
            dedup_track_crops: self.dedup_track_crops,
            models,
            control_plane_url: self.control_plane_url,
            worker_auth,
            nvr_scheme: self.nvr_scheme,
            nvr_read_port: self.nvr_read_port,
            nvr_host_suffix: non_empty_opt(self.nvr_host_suffix),
            nvr_tls_ca_file: non_empty_path(self.nvr_tls_ca_file),
            nvr_tls_cert_file: non_empty_path(self.nvr_tls_cert_file),
            nvr_tls_key_file: non_empty_path(self.nvr_tls_key_file),
            nvr_auth_token_file: non_empty_path(self.nvr_auth_token_file),
            nats_url: self.nats_url,
            nats_creds_file: non_empty_path(self.nats_creds_file),
            nats_tls_ca_file: non_empty_path(self.nats_tls_ca_file),
            nats_tls_cert_file: non_empty_path(self.nats_tls_cert_file),
            nats_tls_key_file: non_empty_path(self.nats_tls_key_file),
            nats_cert_policy_file: non_empty_path(self.nats_cert_policy_file),
            nats_domain: non_empty_opt(self.nats_domain),
            nats_inbox_prefix,
            jobs_stream_name: "CAMERA_MEDIA_JOBS".to_string(),
            results_stream_name: "CAMERA_MEDIA_RESULTS".to_string(),
            consumer_name: "camera_visual_index_worker_v1".to_string(),
            otel_endpoint: self.otel_endpoint,
            vantage_vlm_enabled: self.vantage_vlm_enabled,
            vantage_vlm_url,
            vantage_vlm_model,
            vantage_vlm_api_key,
            vantage_vlm_timeout_ms,
            vantage_vlm_concurrency: self.vantage_vlm_concurrency,
            vantage_consumer_name,
            worker_id,
        })
    }
}

/// A literal NATS subject prefix: dot-separated, non-empty tokens with no
/// wildcards or whitespace, taken as given (no trimming), since it must match the
/// broker's ACL byte for byte. The client appends `.<id>` to it for every inbox.
fn validate_nats_inbox_prefix(prefix: &str) -> Result<String, CapabilityError> {
    let valid = !prefix.is_empty()
        && prefix.split('.').all(|token| {
            !token.is_empty()
                && !token
                    .chars()
                    .any(|c| c == '*' || c == '>' || c.is_whitespace())
        });
    if valid {
        Ok(prefix.to_string())
    } else {
        Err(CapabilityError::invalid_configuration(format!(
            "invalid nats_inbox_prefix '{prefix}': expected dot-separated subject tokens without wildcards or whitespace"
        )))
    }
}

fn non_empty_opt(val: Option<String>) -> Option<String> {
    val.map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn non_empty_path(path: Option<PathBuf>) -> Option<PathBuf> {
    path.filter(|p| !p.as_os_str().is_empty())
}

#[cfg(test)]
mod nats_inbox_prefix_tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<WorkerConfig, CapabilityError> {
        let mut argv = vec!["serviceradar-media-worker"];
        argv.extend_from_slice(args);
        CliArgs::try_parse_from(argv)
            .expect("arguments parse")
            .into_worker_config()
    }

    #[test]
    fn defaults_to_the_dedicated_worker_inbox_prefix() {
        let config = parse(&[]).expect("default config");
        assert_eq!(config.nats_inbox_prefix(), "_INBOX.media-worker");
    }

    #[test]
    fn accepts_an_operator_prefix() {
        let config = parse(&["--nats-inbox-prefix", "_INBOX.site-a-worker"]).expect("config");
        assert_eq!(config.nats_inbox_prefix(), "_INBOX.site-a-worker");
    }

    #[test]
    fn rejects_prefixes_that_are_not_literal_subjects() {
        for prefix in [
            "",
            "_INBOX.>",
            "_INBOX.*.worker",
            "_INBOX..worker",
            "_INBOX.",
            "_INBOX.a b",
            " _INBOX.media-worker ",
        ] {
            assert!(
                parse(&["--nats-inbox-prefix", prefix]).is_err(),
                "prefix {prefix:?} was accepted"
            );
        }
    }

    #[test]
    fn normalizes_vantage_vlm_urls_and_redacts_api_key_in_debug() {
        assert_eq!(
            normalize_vlm_url("http://camera-vlm.example.invalid:8080").unwrap(),
            "http://camera-vlm.example.invalid:8080/v1/chat/completions"
        );
        assert_eq!(
            normalize_vlm_url("https://camera-vlm.example.invalid/v1/").unwrap(),
            "https://camera-vlm.example.invalid/v1/chat/completions"
        );
        assert_eq!(
            normalize_vlm_url("http://camera-vlm.example.invalid/v1/chat/completions").unwrap(),
            "http://camera-vlm.example.invalid/v1/chat/completions"
        );
        assert!(normalize_vlm_url("ftp://bad.example.invalid").is_err());

        let secret = "test-vlm-key-000000";
        let cfg = parse(&[
            "--vantage-vlm-enabled",
            "true",
            "--vantage-vlm-url",
            "http://camera-vlm.example.invalid:8080/v1",
            "--vantage-vlm-api-key",
            secret,
            "--vantage-vlm-concurrency",
            "3",
        ])
        .expect("parse vantage VLM CLI args");

        assert!(cfg.vantage_vlm_enabled());
        assert_eq!(
            cfg.vantage_vlm_url(),
            Some("http://camera-vlm.example.invalid:8080/v1/chat/completions")
        );
        assert_eq!(cfg.vantage_vlm_concurrency(), 3);
        let debug_str = format!("{cfg:?}");
        assert!(
            !debug_str.contains(secret),
            "WorkerConfig Debug leaked VLM API key: {debug_str}"
        );
    }
}
