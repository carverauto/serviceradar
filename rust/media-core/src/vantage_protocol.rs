//! Canonical `vantage.worker.v1` wire envelopes and frame context contracts shared across
//! `serviceradar-media-core`, `serviceradar-media-worker`, and `serviceradar-sdk-vantage`.

use crate::crop::{
    CropConfig, DEFAULT_CROP_PADDING_RATIO, DEFAULT_MAX_CROP_BYTES, DEFAULT_MAX_CROP_DIMENSION,
    DEFAULT_MIN_BBOX_WIDTH_PX, RoiPolygon, STORED_PREVIEW_MAX_BYTES,
};
use crate::detector::Detection;
use crate::error::MediaCoreError;
use crate::frame::RgbFrame;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const VANTAGE_JOB_SCHEMA_VERSION: &str = "vantage.job.v1";
pub const VANTAGE_RESULT_SCHEMA_VERSION: &str = "vantage.result.v1";
pub const VANTAGE_HEARTBEAT_SCHEMA_VERSION: &str = "vantage.heartbeat.v1";
pub const VANTAGE_FRAME_SCHEMA_VERSION: &str = "vantage.frame.v1";
pub const VANTAGE_WORKER_PROTOCOL_VERSION: &str = "vantage.worker.v1";

pub const VANTAGE_RESULTS_SUBJECT: &str = "media.results.vantage.v1";
pub const VANTAGE_VLM_JOBS_SUBJECT: &str = "media.jobs.vantage.vlm.v1";
pub const VANTAGE_VLM_BACKFILL_SUBJECT: &str = "media.jobs.vantage.vlm.backfill.v1";
pub const VANTAGE_HEARTBEAT_SUBJECT: &str = "media.workers.heartbeat.v1";

pub const MAX_VANTAGE_JOB_ENVELOPE_BYTES: usize = 4 * 1024;
pub const MAX_VANTAGE_RESULT_ENVELOPE_BYTES: usize = 960 * 1024;
pub const MAX_STORED_CROP_JPEG_BYTES: usize = STORED_PREVIEW_MAX_BYTES;
pub const DEFAULT_VANTAGE_JOB_BUDGET_MS: u64 = 30_000;
pub const MAX_VLM_MAX_TOKENS: u32 = 4096;

/// Normalizes a capability string such as `"vantage.alpr.v1"` into a NATS-safe subject slug
/// (`"vantage_alpr_v1"`).
pub fn capability_slug(capability: &str) -> String {
    let mut slug = String::with_capacity(capability.len());
    let mut prev_underscore = false;
    for ch in capability.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            prev_underscore = false;
        } else if !prev_underscore && !slug.is_empty() {
            slug.push('_');
            prev_underscore = true;
        }
    }
    while slug.ends_with('_') {
        slug.pop();
    }
    slug
}

/// Returns the JetStream subject for a Vantage capability (`media.jobs.vantage.<slug>.v1` or
/// `media.jobs.vantage.<slug>.backfill.v1`).
pub fn job_subject_for_capability(capability: &str, backfill: bool) -> String {
    let slug = capability_slug(capability);
    if backfill {
        format!("media.jobs.vantage.{slug}.backfill.v1")
    } else {
        format!("media.jobs.vantage.{slug}.v1")
    }
}

/// Returns the core-NATS live keyframe tap subject (`media.live.vantage.<slug>.v1`).
pub fn live_subject_for_capability(capability: &str) -> String {
    let slug = capability_slug(capability);
    format!("media.live.vantage.{slug}.v1")
}

/// Recording or live-tap acquisition mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceMode {
    RecordedBlock,
    LiveKeyframeTap,
}

/// Timestamp origin basis for timeline alignment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimeBasis {
    #[default]
    Received,
    CameraReported,
}

/// Visual input extraction mode declared by a `VantagePipeline`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputMode {
    FullFrame,
    DetectionCrop,
    MultiFrameTrack,
}

/// Execution runtime family emitting observations or worker heartbeats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerKind {
    CameraVlm,
    ExternalRust,
    ExternalPython,
}

/// Worker operational health state advertised via `media.workers.heartbeat.v1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerHealth {
    Ready,
    Degraded,
    Draining,
    Unhealthy,
}

/// Payload encoding used on `media.live.vantage.<capability_slug>.v1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiveFramePayloadFormat {
    AnnexBIdr,
    Jpeg,
    Rgb8,
}

fn default_padding_ratio() -> f32 {
    DEFAULT_CROP_PADDING_RATIO
}

fn default_min_bbox_width_px() -> u32 {
    DEFAULT_MIN_BBOX_WIDTH_PX
}

fn default_max_dimension() -> u32 {
    DEFAULT_MAX_CROP_DIMENSION
}

fn default_max_bytes() -> usize {
    DEFAULT_MAX_CROP_BYTES
}

/// Wire-level crop extraction policy embedded in `VantageJobEnvelope`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CropPolicy {
    #[serde(default = "default_padding_ratio")]
    pub padding_ratio: f32,
    #[serde(default = "default_min_bbox_width_px")]
    pub min_bbox_width_px: u32,
    #[serde(default = "default_max_dimension")]
    pub max_dimension: u32,
    #[serde(default = "default_max_bytes")]
    pub max_bytes: usize,
}

impl Default for CropPolicy {
    fn default() -> Self {
        Self {
            padding_ratio: DEFAULT_CROP_PADDING_RATIO,
            min_bbox_width_px: DEFAULT_MIN_BBOX_WIDTH_PX,
            max_dimension: DEFAULT_MAX_CROP_DIMENSION,
            max_bytes: DEFAULT_MAX_CROP_BYTES,
        }
    }
}

impl CropPolicy {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        self.to_crop_config().validate()
    }

    pub fn to_crop_config(&self) -> CropConfig {
        CropConfig {
            padding_ratio: self.padding_ratio,
            min_bbox_width_px: self.min_bbox_width_px,
            ..CropConfig::default()
        }
        .with_bounds(self.max_dimension, self.max_bytes)
    }
}

impl CropConfig {
    fn with_bounds(mut self, max_dimension: u32, max_bytes: usize) -> Self {
        self.max_dimension = max_dimension;
        self.max_bytes = max_bytes;
        self
    }
}

/// Sampled Stage 1 detection or frame target included in a `VantageJobEnvelope`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SampledTarget {
    pub target_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    pub fragment_sequence: u32,
    pub media_pts_ns: u64,
    pub timeline_ts_us: i64,
    #[serde(default)]
    pub time_basis: TimeBasis,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub confidence: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bbox: Option<[f32; 4]>,
}

impl SampledTarget {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.target_key.trim().is_empty() {
            return Err(MediaCoreError::invalid_configuration(
                "sampled_target.target_key must be non-empty",
            ));
        }
        if !self.confidence.is_finite() || !(0.0..=1.0).contains(&self.confidence) {
            return Err(MediaCoreError::invalid_configuration(format!(
                "sampled_target.confidence {} must be finite and in 0.0..=1.0",
                self.confidence
            )));
        }
        if let Some(bbox) = self.bbox {
            validate_unit_bbox(bbox, "sampled_target.bbox")?;
        }
        Ok(())
    }
}

fn default_vlm_max_tokens() -> u32 {
    256
}

/// Declarative VLM prompt and schema parameters for Ramp 1 `camera_vlm` execution.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VlmJobConfig {
    #[serde(default)]
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_profile: Option<String>,
    #[serde(default = "default_vlm_max_tokens")]
    pub max_tokens: u32,
    #[serde(default)]
    pub temperature: f32,
    #[serde(
        default,
        alias = "response_schema",
        skip_serializing_if = "Option::is_none"
    )]
    pub json_schema: Option<serde_json::Value>,
}

impl Default for VlmJobConfig {
    fn default() -> Self {
        Self {
            prompt: String::new(),
            system_prompt: None,
            model_profile: None,
            max_tokens: default_vlm_max_tokens(),
            temperature: 0.0,
            json_schema: None,
        }
    }
}

impl VlmJobConfig {
    /// Returns `true` when no VLM prompt, system prompt, model profile, or schema is populated
    /// (for example `"vlm_config": {}` emitted for non-VLM `external_worker` pipelines).
    pub fn is_empty(&self) -> bool {
        self.prompt.trim().is_empty()
            && self
                .system_prompt
                .as_deref()
                .is_none_or(|s| s.trim().is_empty())
            && self
                .model_profile
                .as_deref()
                .is_none_or(|s| s.trim().is_empty())
            && self.json_schema.is_none()
    }

    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if !self.is_empty() && self.prompt.trim().is_empty() {
            return Err(MediaCoreError::invalid_configuration(
                "vlm_config.prompt must be non-empty",
            ));
        }
        if self.max_tokens == 0 || self.max_tokens > MAX_VLM_MAX_TOKENS {
            return Err(MediaCoreError::invalid_configuration(format!(
                "vlm_config.max_tokens {} must be in 1..={MAX_VLM_MAX_TOKENS}",
                self.max_tokens
            )));
        }
        if !self.temperature.is_finite() || !(0.0..=2.0).contains(&self.temperature) {
            return Err(MediaCoreError::invalid_configuration(format!(
                "vlm_config.temperature {} must be finite and in 0.0..=2.0",
                self.temperature
            )));
        }
        Ok(())
    }

    /// Strict validation required by Ramp 1 VLM execution (`camera_vlm`), rejecting empty prompts.
    pub fn validate_for_vlm(&self) -> Result<(), MediaCoreError> {
        if self.prompt.trim().is_empty() {
            return Err(MediaCoreError::invalid_configuration(
                "vlm_config.prompt must be non-empty for VLM execution",
            ));
        }
        self.validate()
    }
}

fn default_vantage_job_budget_ms() -> u64 {
    DEFAULT_VANTAGE_JOB_BUDGET_MS
}

/// Metadata-only job envelope published to `media.jobs.vantage.<target>.v1` (`<= 4 KiB`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VantageJobEnvelope {
    pub schema_version: String,
    pub job_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pack_id: Option<String>,
    pub pipeline_id: String,
    pub pipeline_version: String,
    pub capability: String,
    pub source_mode: SourceMode,
    pub camera_source_id: Uuid,
    pub stream_profile_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog_entry_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub descriptor_sha256: Option<String>,
    pub input_mode: InputMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roi_polygons: Vec<RoiPolygon>,
    #[serde(default)]
    pub crop_policy: CropPolicy,
    #[serde(default)]
    pub sampled_targets: Vec<SampledTarget>,
    pub signal_schema_id: String,
    pub signal_schema_version: String,
    pub display_contract_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vlm_config: Option<VlmJobConfig>,
    #[serde(default = "default_vantage_job_budget_ms")]
    pub budget_ms: u64,
    #[serde(default)]
    pub pipeline_config: serde_json::Value,
}

impl VantageJobEnvelope {
    /// Returns explicit `pack_id` if present and non-empty, otherwise derives it from `pipeline_id`.
    pub fn resolved_pack_id(&self) -> String {
        if let Some(pack_id) = self.pack_id.as_deref().map(str::trim)
            && !pack_id.is_empty()
        {
            return pack_id.to_string();
        }
        derive_pack_id_from_pipeline(&self.pipeline_id)
    }

    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.schema_version != VANTAGE_JOB_SCHEMA_VERSION {
            return Err(MediaCoreError::invalid_configuration(format!(
                "unsupported vantage job schema_version '{}', expected '{VANTAGE_JOB_SCHEMA_VERSION}'",
                self.schema_version
            )));
        }
        require_non_empty(&self.pipeline_id, "pipeline_id")?;
        require_non_empty(&self.pipeline_version, "pipeline_version")?;
        require_non_empty(&self.capability, "capability")?;
        require_non_empty(&self.signal_schema_id, "signal_schema_id")?;
        require_non_empty(&self.signal_schema_version, "signal_schema_version")?;
        require_non_empty(&self.display_contract_id, "display_contract_id")?;

        if self.source_mode == SourceMode::RecordedBlock {
            if self.catalog_entry_id.is_none() {
                return Err(MediaCoreError::invalid_configuration(
                    "recorded_block vantage job requires catalog_entry_id",
                ));
            }
            let sha = self.descriptor_sha256.as_deref().ok_or_else(|| {
                MediaCoreError::invalid_configuration(
                    "recorded_block vantage job requires descriptor_sha256",
                )
            })?;
            validate_sha256_hex(sha, "descriptor_sha256")?;
        } else if let Some(sha) = self.descriptor_sha256.as_deref() {
            validate_sha256_hex(sha, "descriptor_sha256")?;
        }

        for roi in &self.roi_polygons {
            roi.validate()?;
        }
        self.crop_policy.validate()?;
        for target in &self.sampled_targets {
            target.validate()?;
            if self.input_mode != InputMode::FullFrame && target.bbox.is_none() {
                return Err(MediaCoreError::invalid_configuration(format!(
                    "sampled_target '{}' requires bbox when input_mode != full_frame",
                    target.target_key
                )));
            }
        }
        if let Some(vlm) = &self.vlm_config {
            vlm.validate()?;
        }
        if self.budget_ms == 0 {
            return Err(MediaCoreError::invalid_configuration(
                "vantage job budget_ms must be non-zero",
            ));
        }

        Ok(())
    }

    /// Serializes the envelope and ensures it fits within [`MAX_VANTAGE_JOB_ENVELOPE_BYTES`].
    pub fn to_bounded_json_bytes(&self) -> Result<Vec<u8>, MediaCoreError> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|err| {
            MediaCoreError::invalid_configuration(format!(
                "failed serializing VantageJobEnvelope: {err}"
            ))
        })?;
        if bytes.len() > MAX_VANTAGE_JOB_ENVELOPE_BYTES {
            return Err(MediaCoreError::invalid_configuration(format!(
                "VantageJobEnvelope serialized size {} exceeds {} bytes",
                bytes.len(),
                MAX_VANTAGE_JOB_ENVELOPE_BYTES
            )));
        }
        Ok(bytes)
    }
}

fn derive_pack_id_from_pipeline(pipeline_id: &str) -> String {
    let trimmed = pipeline_id.trim();
    match trimmed.rsplit_once('.') {
        Some((prefix, _)) if !prefix.is_empty() => prefix.to_string(),
        _ => trimmed.to_string(),
    }
}

/// Single structured ML observation inside a [`VantageResultEnvelope`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VantageObservationInput {
    pub observation_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fragment_sequence: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub media_pts_ns: Option<u64>,
    pub timeline_ts_us: i64,
    pub time_basis: TimeBasis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    pub category: String,
    pub label: String,
    pub confidence: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bbox: Option<[f32; 4]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub crop_jpeg_b64: Option<String>,
    #[serde(default)]
    pub attributes: serde_json::Value,
    pub signal_schema_id: String,
    pub signal_schema_version: String,
    pub display_contract_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_text: Option<String>,
}

impl VantageObservationInput {
    /// Computes the deterministic idempotency key (`sha256` hex) for this observation.
    pub fn compute_observation_key(
        pipeline_id: &str,
        camera_source_id: Option<Uuid>,
        catalog_entry_id: Option<Uuid>,
        fragment_sequence: Option<u32>,
        frame_sequence: Option<u64>,
        track_id: Option<&str>,
        category: &str,
    ) -> String {
        let scope = match (catalog_entry_id, camera_source_id) {
            (Some(entry_id), _) => entry_id.to_string(),
            (None, Some(cam_id)) => format!("live:{cam_id}"),
            (None, None) => "live".to_string(),
        };
        let seq = fragment_sequence
            .map(u64::from)
            .or(frame_sequence)
            .unwrap_or(0);
        let track = track_id.unwrap_or("scene");
        let canonical = format!("{pipeline_id}|{scope}|{seq}|{track}|{category}");
        hex::encode(Sha256::digest(canonical.as_bytes()))
    }

    pub fn validate(&self) -> Result<(), MediaCoreError> {
        require_non_empty(&self.observation_key, "observation_key")?;
        require_non_empty(&self.category, "category")?;
        require_non_empty(&self.label, "label")?;
        require_non_empty(&self.signal_schema_id, "signal_schema_id")?;
        require_non_empty(&self.signal_schema_version, "signal_schema_version")?;
        require_non_empty(&self.display_contract_id, "display_contract_id")?;

        if !self.confidence.is_finite() || !(0.0..=1.0).contains(&self.confidence) {
            return Err(MediaCoreError::invalid_configuration(format!(
                "observation confidence {} must be finite and in 0.0..=1.0",
                self.confidence
            )));
        }
        if let Some(bbox) = self.bbox {
            validate_unit_bbox(bbox, "observation.bbox")?;
        }
        if let Some(crop_b64) = &self.crop_jpeg_b64 {
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(crop_b64)
                .map_err(|err| {
                    MediaCoreError::thumbnail(format!("invalid observation crop_jpeg_b64: {err}"))
                })?;
            if decoded.len() > MAX_STORED_CROP_JPEG_BYTES {
                return Err(MediaCoreError::thumbnail(format!(
                    "observation crop_jpeg exceeds {} bytes (got {} bytes)",
                    MAX_STORED_CROP_JPEG_BYTES,
                    decoded.len()
                )));
            }
            if decoded.len() < 4
                || decoded[0] != 0xFF
                || decoded[1] != 0xD8
                || decoded[decoded.len() - 2] != 0xFF
                || decoded[decoded.len() - 1] != 0xD9
            {
                return Err(MediaCoreError::thumbnail(
                    "observation crop_jpeg_b64 must be a complete JPEG payload (SOI..EOI)",
                ));
            }
        }
        Ok(())
    }
}

/// Result batch envelope published to JetStream `media.results.vantage.v1` (`<= 960 KiB`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VantageResultEnvelope {
    pub schema_version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<Uuid>,
    pub pack_id: String,
    pub pipeline_id: String,
    pub pipeline_version: String,
    pub worker_kind: WorkerKind,
    pub worker_id: String,
    pub model_id: String,
    pub model_version: String,
    pub capability: String,
    pub source_mode: SourceMode,
    pub camera_source_id: Uuid,
    pub stream_profile_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog_entry_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub descriptor_sha256: Option<String>,
    #[serde(default)]
    pub observations: Vec<VantageObservationInput>,
}

impl VantageResultEnvelope {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.schema_version != VANTAGE_RESULT_SCHEMA_VERSION {
            return Err(MediaCoreError::invalid_configuration(format!(
                "unsupported vantage result schema_version '{}', expected '{VANTAGE_RESULT_SCHEMA_VERSION}'",
                self.schema_version
            )));
        }
        require_non_empty(&self.pack_id, "pack_id")?;
        require_non_empty(&self.pipeline_id, "pipeline_id")?;
        require_non_empty(&self.pipeline_version, "pipeline_version")?;
        require_non_empty(&self.worker_id, "worker_id")?;
        require_non_empty(&self.model_id, "model_id")?;
        require_non_empty(&self.model_version, "model_version")?;
        require_non_empty(&self.capability, "capability")?;

        if let Some(sha) = self.descriptor_sha256.as_deref() {
            validate_sha256_hex(sha, "descriptor_sha256")?;
        }
        for obs in &self.observations {
            obs.validate()?;
        }
        Ok(())
    }

    /// Serializes the envelope to JSON and enforces [`MAX_VANTAGE_RESULT_ENVELOPE_BYTES`] (`960 KiB`).
    pub fn to_bounded_json_bytes(&self) -> Result<Vec<u8>, MediaCoreError> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|err| {
            MediaCoreError::invalid_configuration(format!(
                "failed serializing VantageResultEnvelope: {err}"
            ))
        })?;
        if bytes.len() > MAX_VANTAGE_RESULT_ENVELOPE_BYTES {
            return Err(MediaCoreError::thumbnail(format!(
                "VantageResultEnvelope serialized size {} exceeds {} bytes",
                bytes.len(),
                MAX_VANTAGE_RESULT_ENVELOPE_BYTES
            )));
        }
        Ok(bytes)
    }
}

/// Worker capability advertisement & health heartbeat (`media.workers.heartbeat.v1`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VantageWorkerHeartbeat {
    pub schema_version: String,
    pub worker_id: String,
    pub worker_kind: WorkerKind,
    pub protocol_version: String,
    pub capabilities: Vec<String>,
    pub supported_source_modes: Vec<SourceMode>,
    pub execution_backend: String,
    pub architecture: String,
    pub model_id: String,
    pub model_version: String,
    pub max_concurrency: u32,
    pub active_jobs: u32,
    pub health: WorkerHealth,
    pub sent_at_us: i64,
}

impl VantageWorkerHeartbeat {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.schema_version != VANTAGE_HEARTBEAT_SCHEMA_VERSION {
            return Err(MediaCoreError::invalid_configuration(format!(
                "unsupported heartbeat schema_version '{}', expected '{VANTAGE_HEARTBEAT_SCHEMA_VERSION}'",
                self.schema_version
            )));
        }
        if self.protocol_version != VANTAGE_WORKER_PROTOCOL_VERSION {
            return Err(MediaCoreError::invalid_configuration(format!(
                "unsupported heartbeat protocol_version '{}', expected '{VANTAGE_WORKER_PROTOCOL_VERSION}'",
                self.protocol_version
            )));
        }
        require_non_empty(&self.worker_id, "worker_id")?;
        require_non_empty(&self.execution_backend, "execution_backend")?;
        require_non_empty(&self.architecture, "architecture")?;
        require_non_empty(&self.model_id, "model_id")?;
        require_non_empty(&self.model_version, "model_version")?;
        if self.capabilities.is_empty() {
            return Err(MediaCoreError::invalid_configuration(
                "heartbeat capabilities must not be empty",
            ));
        }
        if self.supported_source_modes.is_empty() {
            return Err(MediaCoreError::invalid_configuration(
                "heartbeat supported_source_modes must not be empty",
            ));
        }
        if self.max_concurrency == 0 {
            return Err(MediaCoreError::invalid_configuration(
                "heartbeat max_concurrency must be non-zero",
            ));
        }
        Ok(())
    }
}

/// Upstream Stage 1 detection optionally enriched with tracker identity metadata.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VantageUpstreamDetection {
    #[serde(flatten)]
    pub detection: Detection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_key: Option<String>,
}

impl From<Detection> for VantageUpstreamDetection {
    fn from(detection: Detection) -> Self {
        Self {
            detection,
            track_id: None,
            target_key: None,
        }
    }
}

/// Unified in-memory frame context shared by both recorded-block and live-tap workers
/// (`design.md § Decision 4`).
#[derive(Debug, Clone, PartialEq)]
pub struct VantageFrameContext {
    pub source_mode: SourceMode,
    pub camera_source_id: Uuid,
    pub stream_profile_id: Uuid,
    pub catalog_entry_id: Option<Uuid>,
    pub fragment_sequence: Option<u32>,
    pub frame_sequence: u64,
    pub timeline_ts_us: i64,
    pub time_basis: TimeBasis,
    pub rgb_frame: RgbFrame,
    pub upstream_detections: Vec<VantageUpstreamDetection>,
    pub pipeline_config: serde_json::Value,
}

/// Serializable live-tap frame envelope published onto `media.live.vantage.<capability_slug>.v1`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VantageLiveFrameEnvelope {
    pub schema_version: String,
    pub source_mode: SourceMode,
    pub camera_source_id: Uuid,
    pub stream_profile_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog_entry_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fragment_sequence: Option<u32>,
    pub frame_sequence: u64,
    pub timeline_ts_us: i64,
    pub time_basis: TimeBasis,
    #[serde(default)]
    pub detections: Vec<VantageUpstreamDetection>,
    pub payload_format: LiveFramePayloadFormat,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload_b64: Option<String>,
    #[serde(default)]
    pub pipeline_config: serde_json::Value,
}

impl VantageLiveFrameEnvelope {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.schema_version != VANTAGE_FRAME_SCHEMA_VERSION {
            return Err(MediaCoreError::invalid_configuration(format!(
                "unsupported live frame schema_version '{}', expected '{VANTAGE_FRAME_SCHEMA_VERSION}'",
                self.schema_version
            )));
        }
        Ok(())
    }
}

fn require_non_empty(value: &str, field: &str) -> Result<(), MediaCoreError> {
    if value.trim().is_empty() {
        return Err(MediaCoreError::invalid_configuration(format!(
            "vantage field '{field}' must be non-empty"
        )));
    }
    Ok(())
}

fn validate_sha256_hex(hex_str: &str, field: &str) -> Result<(), MediaCoreError> {
    if hex_str.len() != 64
        || !hex_str
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        return Err(MediaCoreError::invalid_configuration(format!(
            "vantage field '{field}' must be 64 lowercase hex characters"
        )));
    }
    Ok(())
}

fn validate_unit_bbox(bbox: [f32; 4], field: &str) -> Result<(), MediaCoreError> {
    let [x1, y1, x2, y2] = bbox;
    if !x1.is_finite()
        || !y1.is_finite()
        || !x2.is_finite()
        || !y2.is_finite()
        || !(0.0..=1.0).contains(&x1)
        || !(0.0..=1.0).contains(&y1)
        || !(0.0..=1.0).contains(&x2)
        || !(0.0..=1.0).contains(&y2)
        || x2 <= x1
        || y2 <= y1
    {
        return Err(MediaCoreError::invalid_configuration(format!(
            "{field} must be normalized [x1, y1, x2, y2] in 0.0..=1.0 with x2 > x1 and y2 > y1, got {bbox:?}"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detector::ObjectCategory;

    #[test]
    fn capability_slug_and_subjects_match_contract() {
        assert_eq!(capability_slug("vantage.alpr.v1"), "vantage_alpr_v1");
        assert_eq!(
            capability_slug("vantage.bay_guidance.v1"),
            "vantage_bay_guidance_v1"
        );
        assert_eq!(
            job_subject_for_capability("vantage.alpr.v1", false),
            "media.jobs.vantage.vantage_alpr_v1.v1"
        );
        assert_eq!(
            job_subject_for_capability("vantage.alpr.v1", true),
            "media.jobs.vantage.vantage_alpr_v1.backfill.v1"
        );
        assert_eq!(
            live_subject_for_capability("vantage.bay_guidance.v1"),
            "media.live.vantage.vantage_bay_guidance_v1.v1"
        );
    }

    #[test]
    fn vantage_job_result_heartbeat_and_live_envelopes_round_trip_and_validate() {
        let job_id = Uuid::new_v4();
        let camera_id = Uuid::new_v4();
        let profile_id = Uuid::new_v4();
        let catalog_id = Uuid::new_v4();
        let desc_sha = "a".repeat(64);

        let job_json = serde_json::json!({
            "schema_version": "vantage.job.v1",
            "job_id": job_id,
            "pipeline_id": "io.serviceradar.vantage-alpr.vehicle-plate",
            "pipeline_version": "1.0.0",
            "capability": "vantage.alpr.v1",
            "source_mode": "recorded_block",
            "camera_source_id": camera_id,
            "stream_profile_id": profile_id,
            "catalog_entry_id": catalog_id,
            "descriptor_sha256": desc_sha,
            "input_mode": "detection_crop",
            "roi_polygons": [[[0.1, 0.2], [0.9, 0.2], [0.9, 0.9], [0.1, 0.9]]],
            "crop_policy": {"padding_ratio": 0.15, "min_bbox_width_px": 96, "max_dimension": 640, "max_bytes": 98304},
            "sampled_targets": [{
                "target_key": "track-1",
                "track_id": "1",
                "fragment_sequence": 1,
                "media_pts_ns": 1_000_000_000u64,
                "timeline_ts_us": 1_700_000_000_000_000i64,
                "time_basis": "received",
                "category": "vehicle",
                "confidence": 0.87,
                "bbox": [0.3, 0.45, 0.55, 0.8]
            }],
            "signal_schema_id": "alpr_plate_read",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "alpr_plate_read",
            "vlm_config": {
                "prompt": "Read the license plate at Gate West 01",
                "model_profile": "qwen3.5-4b",
                "max_tokens": 256,
                "temperature": 0.0,
                "response_schema": {"type": "object", "required": ["plate_text"]}
            }
        });

        let job: VantageJobEnvelope =
            serde_json::from_value(job_json).expect("deserialize vantage job");
        assert_eq!(job.resolved_pack_id(), "io.serviceradar.vantage-alpr");
        assert!(
            job.vlm_config
                .as_ref()
                .and_then(|c| c.json_schema.as_ref())
                .is_some(),
            "response_schema alias must deserialize into VlmJobConfig.json_schema"
        );
        let job_bytes = job.to_bounded_json_bytes().expect("valid bounded job JSON");
        assert!(job_bytes.len() <= MAX_VANTAGE_JOB_ENVELOPE_BYTES);

        let obs_key = VantageObservationInput::compute_observation_key(
            &job.pipeline_id,
            Some(camera_id),
            Some(catalog_id),
            Some(1),
            Some(1),
            Some("1"),
            "license_plate",
        );
        assert_eq!(
            obs_key,
            VantageObservationInput::compute_observation_key(
                &job.pipeline_id,
                Some(camera_id),
                Some(catalog_id),
                Some(1),
                Some(1),
                Some("1"),
                "license_plate",
            )
        );

        let minimal_jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9];
        let result = VantageResultEnvelope {
            schema_version: VANTAGE_RESULT_SCHEMA_VERSION.to_string(),
            job_id: Some(job_id),
            pack_id: job.resolved_pack_id(),
            pipeline_id: job.pipeline_id.clone(),
            pipeline_version: job.pipeline_version.clone(),
            worker_kind: WorkerKind::CameraVlm,
            worker_id: "media-worker-synthetic-01".to_string(),
            model_id: "qwen3.5-4b".to_string(),
            model_version: "1.0.0".to_string(),
            capability: job.capability.clone(),
            source_mode: SourceMode::RecordedBlock,
            camera_source_id: camera_id,
            stream_profile_id: profile_id,
            catalog_entry_id: Some(catalog_id),
            descriptor_sha256: Some(desc_sha),
            observations: vec![VantageObservationInput {
                observation_key: obs_key,
                fragment_sequence: Some(1),
                frame_sequence: Some(1),
                media_pts_ns: Some(1_000_000_000),
                timeline_ts_us: 1_700_000_000_000_000,
                time_basis: TimeBasis::Received,
                track_id: Some("1".to_string()),
                category: "license_plate".to_string(),
                label: "SR-0100".to_string(),
                confidence: 0.94,
                bbox: Some([0.32, 0.58, 0.48, 0.66]),
                crop_jpeg_b64: Some(base64::engine::general_purpose::STANDARD.encode(minimal_jpeg)),
                attributes: serde_json::json!({
                    "plate_text": "SR-0100",
                    "gate": "Gate West 01"
                }),
                signal_schema_id: "alpr_plate_read".to_string(),
                signal_schema_version: "1.0.0".to_string(),
                display_contract_id: "alpr_plate_read".to_string(),
                search_text: Some("SR-0100 Gate West 01 vehicle license_plate".to_string()),
            }],
        };
        let result_bytes = result
            .to_bounded_json_bytes()
            .expect("valid bounded result envelope");
        let decoded_result: VantageResultEnvelope =
            serde_json::from_slice(&result_bytes).expect("round-trip result");
        assert_eq!(decoded_result, result);

        let hb = VantageWorkerHeartbeat {
            schema_version: VANTAGE_HEARTBEAT_SCHEMA_VERSION.to_string(),
            worker_id: "vantage-alpr-synthetic-01".to_string(),
            worker_kind: WorkerKind::ExternalRust,
            protocol_version: VANTAGE_WORKER_PROTOCOL_VERSION.to_string(),
            capabilities: vec!["vantage.alpr.v1".to_string()],
            supported_source_modes: vec![SourceMode::RecordedBlock, SourceMode::LiveKeyframeTap],
            execution_backend: "onnx".to_string(),
            architecture: "arm64".to_string(),
            model_id: "fast-alpr-synthetic".to_string(),
            model_version: "1.0.0".to_string(),
            max_concurrency: 4,
            active_jobs: 0,
            health: WorkerHealth::Ready,
            sent_at_us: 1_700_000_000_000_000,
        };
        hb.validate().expect("valid heartbeat");
        let hb_rt: VantageWorkerHeartbeat =
            serde_json::from_slice(&serde_json::to_vec(&hb).unwrap()).unwrap();
        assert_eq!(hb_rt, hb);

        let live_env = VantageLiveFrameEnvelope {
            schema_version: VANTAGE_FRAME_SCHEMA_VERSION.to_string(),
            source_mode: SourceMode::LiveKeyframeTap,
            camera_source_id: camera_id,
            stream_profile_id: profile_id,
            catalog_entry_id: None,
            fragment_sequence: None,
            frame_sequence: 42,
            timeline_ts_us: 1_700_000_000_500_000,
            time_basis: TimeBasis::Received,
            detections: vec![VantageUpstreamDetection {
                detection: Detection::new(2, ObjectCategory::Vehicle, 0.91, [0.3, 0.45, 0.55, 0.8]),
                track_id: Some("track-742".to_string()),
                target_key: Some("TEST-742".to_string()),
            }],
            payload_format: LiveFramePayloadFormat::Jpeg,
            payload_b64: Some(base64::engine::general_purpose::STANDARD.encode(minimal_jpeg)),
            pipeline_config: serde_json::json!({"gate": "Gate West 01"}),
        };
        live_env.validate().expect("valid live frame envelope");

        let frame_ctx = VantageFrameContext {
            source_mode: SourceMode::LiveKeyframeTap,
            camera_source_id: camera_id,
            stream_profile_id: profile_id,
            catalog_entry_id: None,
            fragment_sequence: None,
            frame_sequence: 42,
            timeline_ts_us: 1_700_000_000_500_000,
            time_basis: TimeBasis::Received,
            rgb_frame: RgbFrame::solid(64, 64, [25, 25, 30]),
            upstream_detections: live_env.detections.clone(),
            pipeline_config: serde_json::json!({"gate": "Gate West 01"}),
        };
        assert_eq!(frame_ctx.source_mode, SourceMode::LiveKeyframeTap);
        assert_eq!(frame_ctx.rgb_frame.width(), 64);
    }

    #[test]
    fn vantage_validation_rejects_oversized_crops_envelopes_and_missing_recorded_metadata() {
        let camera_id = Uuid::new_v4();
        let profile_id = Uuid::new_v4();

        // RecordedBlock job without catalog_entry_id fails.
        let mut missing_catalog: VantageJobEnvelope = serde_json::from_value(serde_json::json!({
            "schema_version": "vantage.job.v1",
            "job_id": Uuid::new_v4(),
            "pipeline_id": "io.serviceradar.vantage-alpr.vehicle-plate",
            "pipeline_version": "1.0.0",
            "capability": "vantage.alpr.v1",
            "source_mode": "recorded_block",
            "camera_source_id": camera_id,
            "stream_profile_id": profile_id,
            "descriptor_sha256": "b".repeat(64),
            "input_mode": "detection_crop",
            "signal_schema_id": "alpr_plate_read",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "alpr_plate_read"
        }))
        .expect("deserialize");
        assert!(missing_catalog.validate().is_err());

        // Invalid descriptor_sha256 fails.
        missing_catalog.catalog_entry_id = Some(Uuid::new_v4());
        missing_catalog.descriptor_sha256 = Some("not-hex64".to_string());
        assert!(missing_catalog.validate().is_err());

        // Oversized crop_jpeg_b64 (> 32 KiB) fails.
        let mut oversized_jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        oversized_jpeg.resize(MAX_STORED_CROP_JPEG_BYTES + 1, 0x11);
        oversized_jpeg[MAX_STORED_CROP_JPEG_BYTES - 1] = 0xFF;
        oversized_jpeg[MAX_STORED_CROP_JPEG_BYTES] = 0xD9;
        let obs = VantageObservationInput {
            observation_key: "k1".to_string(),
            fragment_sequence: Some(1),
            frame_sequence: Some(1),
            media_pts_ns: Some(100),
            timeline_ts_us: 1_700_000_000_000_000,
            time_basis: TimeBasis::Received,
            track_id: Some("1".to_string()),
            category: "license_plate".to_string(),
            label: "TEST-742".to_string(),
            confidence: 0.9,
            bbox: Some([0.1, 0.2, 0.4, 0.5]),
            crop_jpeg_b64: Some(base64::engine::general_purpose::STANDARD.encode(oversized_jpeg)),
            attributes: serde_json::json!({"plate_text": "TEST-742"}),
            signal_schema_id: "alpr_plate_read".to_string(),
            signal_schema_version: "1.0.0".to_string(),
            display_contract_id: "alpr_plate_read".to_string(),
            search_text: None,
        };
        assert!(obs.validate().is_err());

        // Out-of-range bbox fails.
        let bad_bbox_obs = VantageObservationInput {
            crop_jpeg_b64: None,
            bbox: Some([0.5, 0.2, 0.4, 0.5]),
            ..obs.clone()
        };
        assert!(bad_bbox_obs.validate().is_err());

        // Result envelope > 960 KiB fails to_bounded_json_bytes.
        let big_attr_obs = VantageObservationInput {
            crop_jpeg_b64: None,
            bbox: Some([0.1, 0.2, 0.4, 0.5]),
            attributes: serde_json::json!({"blob": "x".repeat(MAX_VANTAGE_RESULT_ENVELOPE_BYTES)}),
            ..obs
        };
        let oversized_res = VantageResultEnvelope {
            schema_version: VANTAGE_RESULT_SCHEMA_VERSION.to_string(),
            job_id: Some(Uuid::new_v4()),
            pack_id: "io.serviceradar.vantage-alpr".to_string(),
            pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate".to_string(),
            pipeline_version: "1.0.0".to_string(),
            worker_kind: WorkerKind::CameraVlm,
            worker_id: "worker-1".to_string(),
            model_id: "qwen3.5-4b".to_string(),
            model_version: "1.0.0".to_string(),
            capability: "vantage.alpr.v1".to_string(),
            source_mode: SourceMode::RecordedBlock,
            camera_source_id: camera_id,
            stream_profile_id: profile_id,
            catalog_entry_id: Some(Uuid::new_v4()),
            descriptor_sha256: Some("c".repeat(64)),
            observations: vec![big_attr_obs],
        };
        assert!(oversized_res.to_bounded_json_bytes().is_err());
    }

    #[test]
    fn deserializes_m1_admitter_payloads_with_roi_maps_empty_vlm_config_and_sealed_block_targets() {
        let camera_id = Uuid::new_v4();
        let profile_id = Uuid::new_v4();
        let catalog_id = Uuid::new_v4();
        let desc_sha = "d".repeat(64);

        // M1 :on_stage1_detection external_worker payload:
        // - roi_polygons uses %{"points" => [[...]]} and %{"points" => [%{"x" => ..., "y" => ...}]}
        // - vlm_config is %{}
        // - sampled_targets omits time_basis
        let stage1_external_json = serde_json::json!({
            "schema_version": "vantage.job.v1",
            "job_id": Uuid::new_v4(),
            "pipeline_id": "io.serviceradar.vantage-alpr.vehicle-plate",
            "pipeline_version": "1.0.0",
            "capability": "vantage.alpr.v1",
            "source_mode": "recorded_block",
            "camera_source_id": camera_id,
            "stream_profile_id": profile_id,
            "catalog_entry_id": catalog_id,
            "descriptor_sha256": desc_sha,
            "input_mode": "detection_crop",
            "roi_polygons": [
                {"points": [[0.2, 0.4], [0.7, 0.4], [0.7, 0.9], [0.2, 0.9]]},
                {"points": [{"x": 0.1, "y": 0.1}, {"x": 0.5, "y": 0.1}, {"x": 0.5, "y": 0.5}]}
            ],
            "crop_policy": {"padding_ratio": 0.15, "min_bbox_width_px": 96, "max_dimension": 640, "max_bytes": 98304},
            "sampled_targets": [{
                "target_key": "track:1",
                "track_id": "1",
                "fragment_sequence": 1,
                "media_pts_ns": 1_000_000_000u64,
                "timeline_ts_us": 1_700_000_000_000_000i64,
                "category": "vehicle",
                "confidence": 0.88,
                "bbox": [0.3, 0.45, 0.55, 0.8]
            }],
            "signal_schema_id": "alpr_plate_read",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "alpr_plate_read",
            "vlm_config": {}
        });

        let job: VantageJobEnvelope = serde_json::from_value(stage1_external_json)
            .expect("M1 admitter payload with roi_polygons maps, empty vlm_config, and omitted time_basis must deserialize");
        job.validate()
            .expect("external worker job with empty vlm_config must validate");
        assert_eq!(job.roi_polygons.len(), 2);
        assert_eq!(job.sampled_targets[0].time_basis, TimeBasis::Received);
        assert!(job.vlm_config.as_ref().unwrap().is_empty());
        assert!(
            job.vlm_config.as_ref().unwrap().validate_for_vlm().is_err(),
            "Ramp 1 VLM strict validation must reject empty vlm_config"
        );

        // M1 :on_sealed_block payload (input_mode = full_frame, omits time_basis/category/confidence/bbox):
        let sealed_block_json = serde_json::json!({
            "schema_version": "vantage.job.v1",
            "job_id": Uuid::new_v4(),
            "pipeline_id": "io.serviceradar.bay-guidance.gate-occupancy",
            "pipeline_version": "1.0.0",
            "capability": "vantage.bay_guidance.v1",
            "source_mode": "recorded_block",
            "camera_source_id": camera_id,
            "stream_profile_id": profile_id,
            "catalog_entry_id": catalog_id,
            "descriptor_sha256": "e".repeat(64),
            "input_mode": "full_frame",
            "roi_polygons": [],
            "crop_policy": {"padding_ratio": 0.15, "min_bbox_width_px": 96, "max_dimension": 640, "max_bytes": 98304},
            "sampled_targets": [{
                "target_key": "block",
                "fragment_sequence": 1,
                "media_pts_ns": 2_000_000_000u64,
                "timeline_ts_us": 1_700_000_002_000_000i64
            }],
            "signal_schema_id": "bay_guidance_state",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "bay_guidance_state",
            "vlm_config": {
                "prompt": "Report bay occupancy at Gate West 01",
                "max_tokens": 256,
                "temperature": 0.0
            }
        });

        let sealed_job: VantageJobEnvelope =
            serde_json::from_value(sealed_block_json).expect("deserialize on_sealed_block payload");
        sealed_job
            .validate()
            .expect("full_frame on_sealed_block job must validate");
        assert_eq!(sealed_job.input_mode, InputMode::FullFrame);
        assert_eq!(sealed_job.sampled_targets[0].bbox, None);
        assert_eq!(
            sealed_job.sampled_targets[0].time_basis,
            TimeBasis::Received
        );
    }

    #[test]
    fn observation_keys_are_distinct_across_cameras_in_live_tap_and_across_untracked_targets() {
        let cam_a = Uuid::new_v4();
        let cam_b = Uuid::new_v4();
        let live_key_a = VantageObservationInput::compute_observation_key(
            "io.serviceradar.bay-guidance.gate",
            Some(cam_a),
            None,
            None,
            Some(42),
            Some("track-1"),
            "bay_guidance",
        );
        let live_key_b = VantageObservationInput::compute_observation_key(
            "io.serviceradar.bay-guidance.gate",
            Some(cam_b),
            None,
            None,
            Some(42),
            Some("track-1"),
            "bay_guidance",
        );
        assert_ne!(
            live_key_a, live_key_b,
            "live_keyframe_tap observations across two cameras must not collide"
        );

        let entry_id = Uuid::new_v4();
        let det0 = VantageObservationInput::compute_observation_key(
            "io.serviceradar.vantage-alpr.vehicle-plate",
            Some(cam_a),
            Some(entry_id),
            Some(1),
            Some(1),
            Some("frame:1:det:0"),
            "license_plate",
        );
        let det1 = VantageObservationInput::compute_observation_key(
            "io.serviceradar.vantage-alpr.vehicle-plate",
            Some(cam_a),
            Some(entry_id),
            Some(1),
            Some(1),
            Some("frame:1:det:1"),
            "license_plate",
        );
        assert_ne!(
            det0, det1,
            "untracked detections in the same fragment must have distinct observation_keys"
        );
    }
}
