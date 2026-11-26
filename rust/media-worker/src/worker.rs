//! JetStream visual-index pull loop (`WPI` + publish-before-ACK) and reserved
//! interactive NATS text-embedding responder (`2.5`, `5.2`).

use crate::backend::{InferenceBackend, build_inference_backend};
use crate::capability::{
    CapabilityManifest, SystemGpuEnvironmentProbe, verify_startup_capabilities_with_backend,
};
use crate::cmaf::{VideoCodec, parse_init_segment_with_codec, parse_timed_fragment};
use crate::config::{ModelPinConfig, WorkerConfig};
use crate::credentials::WorkerAuthCredentials;
use crate::errors::{IntegrityError, MediaWorkerError, MediaWorkerErrorKind};
use crate::grants::{GrantClient, GrantResolution, HttpControlPlaneGrantClient, ReadGrantRequest};
use crate::http_server::ReadinessState;
use crate::keyframe_decoder::{DefaultKeyframeDecoder, KeyframeDecoder};
use crate::metrics::{MEDIA_WORKER_TELEMETRY_SUBJECT, WorkerMetrics};
use crate::range_reader::{
    FragmentStore, HybridGrantStore, LongshoreArchiveReader, NvrAnalysisReader,
    VerifiedKeyframeBlock,
};
use crate::vantage_vlm::{HttpVlmClient, VantageVlmProcessor};
use crate::vision::VisionPipeline;
use async_nats::jetstream::AckKind;
use async_nats::jetstream::consumer::{AckPolicy, pull};
use async_nats::jetstream::stream::{RetentionPolicy, StorageType};
use async_nats::{Client, ConnectOptions, HeaderMap, jetstream};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use serviceradar_media_core::{
    MAX_VANTAGE_RESULT_ENVELOPE_BYTES, RoiGridMask,
    VANTAGE_RESULTS_SUBJECT as CORE_VANTAGE_RESULTS_SUBJECT,
    VANTAGE_VLM_BACKFILL_SUBJECT as CORE_VANTAGE_VLM_BACKFILL_SUBJECT,
    VANTAGE_VLM_JOBS_SUBJECT as CORE_VANTAGE_VLM_JOBS_SUBJECT, VantageResultEnvelope,
};
use std::collections::BTreeMap;
use std::future::Future;
use std::path::Path;
use std::sync::{Arc, Once};
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tracing::{debug, info, warn};

/// Live visual-indexing job subject published by `ServiceRadar.Camera.VisualIndexDispatcher`.
pub const VISUAL_INDEX_LIVE_SUBJECT: &str = "media.jobs.visual_index.v1";
/// Historical/model-upgrade backfill subject published by `ServiceRadar.Camera.VisualIndexDispatcher`.
pub const VISUAL_INDEX_BACKFILL_SUBJECT: &str = "media.jobs.visual_index.backfill.v1";
/// Idempotent visual-index result subject consumed by `ServiceRadar.Camera.VisualIndexResultProjector`.
pub const VISUAL_INDEX_RESULTS_SUBJECT: &str = "media.results.visual_index.v1";
/// Interactive query text-embedding NATS RPC schema & subject prefix (`ServiceRadar.Camera.SemanticSearch`).
pub const VISUAL_TEXT_EMBED_RPC_PREFIX: &str = "media.rpc.visual_text_embed.v1";
/// Queue group shared by compatible `serviceradar-media-worker` replicas on text-embed RPCs.
pub const VISUAL_TEXT_EMBED_QUEUE_GROUP: &str = "serviceradar_media_worker_text_embed_v1";
/// Safe serialized JSON byte ceiling (960 KiB) for `VisualIndexResultEnvelope`, keeping
/// headroom below NATS's 1 MiB `max_payload`.
pub const MAX_RESULT_ENVELOPE_JSON_BYTES: usize = 960 * 1024;
/// Live Ramp 1 Vantage VLM job subject (`media.jobs.vantage.vlm.v1`).
pub const VANTAGE_VLM_LIVE_SUBJECT: &str = CORE_VANTAGE_VLM_JOBS_SUBJECT;
/// Backfill Ramp 1 Vantage VLM job subject (`media.jobs.vantage.vlm.backfill.v1`).
pub const VANTAGE_VLM_BACKFILL_SUBJECT: &str = CORE_VANTAGE_VLM_BACKFILL_SUBJECT;
/// Idempotent Vantage observation result subject consumed by Core `EventWriter`.
pub const VANTAGE_RESULTS_SUBJECT: &str = CORE_VANTAGE_RESULTS_SUBJECT;

fn default_schema_v1() -> u32 {
    1
}

fn default_budget_ms() -> u64 {
    30_000
}

fn default_text_deadline_ms() -> u64 {
    250
}

/// Metadata-only job envelope consumed from `media.jobs.visual_index.v1` and `.backfill.v1`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VisualIndexJobEnvelope {
    #[serde(default = "default_schema_v1")]
    schema_version: u32,
    job_id: String,
    #[serde(default)]
    job_kind: Option<String>,
    catalog_entry_id: String,
    camera_source_id: String,
    stream_profile_id: String,
    descriptor_sha256: String,
    #[serde(default)]
    detector_model_id: Option<String>,
    #[serde(default)]
    detector_model_version: Option<String>,
    #[serde(default)]
    embedder_model_id: Option<String>,
    #[serde(default)]
    embedder_model_version: Option<String>,
    #[serde(default)]
    model_id: Option<String>,
    #[serde(default)]
    model_version: Option<String>,
    embedding_dim: usize,
    #[serde(default)]
    sampled_fragment_sequences: Vec<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    roi_grid: Option<RoiGridMask>,
    #[serde(default = "default_budget_ms")]
    budget_ms: u64,
    #[serde(default)]
    deadline_unix_ms: Option<i64>,
}

impl VisualIndexJobEnvelope {
    pub fn new(
        job_id: impl Into<String>,
        catalog_entry_id: impl Into<String>,
        camera_source_id: impl Into<String>,
        stream_profile_id: impl Into<String>,
        descriptor_sha256: impl Into<String>,
        models: &ModelPinConfig,
    ) -> Self {
        Self {
            schema_version: 1,
            job_id: job_id.into(),
            job_kind: Some("live".to_string()),
            catalog_entry_id: catalog_entry_id.into(),
            camera_source_id: camera_source_id.into(),
            stream_profile_id: stream_profile_id.into(),
            descriptor_sha256: descriptor_sha256.into(),
            detector_model_id: Some(models.detector_model_id().to_string()),
            detector_model_version: Some(models.detector_model_version().to_string()),
            embedder_model_id: Some(models.embedder_model_id().to_string()),
            embedder_model_version: Some(models.embedder_model_version().to_string()),
            model_id: Some(models.embedder_model_id().to_string()),
            model_version: Some(models.embedder_model_version().to_string()),
            embedding_dim: models.embedding_dim(),
            sampled_fragment_sequences: Vec::new(),
            roi_grid: None,
            budget_ms: 30_000,
            deadline_unix_ms: None,
        }
    }

    pub fn with_budget_ms(mut self, budget_ms: u64) -> Self {
        self.budget_ms = budget_ms;
        self
    }

    pub fn with_roi_grid(mut self, roi_grid: RoiGridMask) -> Self {
        self.roi_grid = Some(roi_grid);
        self
    }

    pub fn roi_grid(&self) -> Option<&RoiGridMask> {
        self.roi_grid.as_ref()
    }

    pub fn job_id(&self) -> &str {
        &self.job_id
    }

    pub fn catalog_entry_id(&self) -> &str {
        &self.catalog_entry_id
    }

    pub fn camera_source_id(&self) -> &str {
        &self.camera_source_id
    }

    pub fn stream_profile_id(&self) -> &str {
        &self.stream_profile_id
    }

    pub fn descriptor_sha256(&self) -> &str {
        &self.descriptor_sha256
    }

    pub fn resolved_embedder_model_id(&self) -> Option<&str> {
        self.embedder_model_id
            .as_deref()
            .or(self.model_id.as_deref())
    }

    pub fn resolved_embedder_model_version(&self) -> Option<&str> {
        self.embedder_model_version
            .as_deref()
            .or(self.model_version.as_deref())
    }

    pub fn resolved_detector_model_id<'a>(&'a self, fallback: &'a str) -> &'a str {
        self.detector_model_id.as_deref().unwrap_or(fallback)
    }

    pub fn resolved_detector_model_version<'a>(&'a self, fallback: &'a str) -> &'a str {
        self.detector_model_version.as_deref().unwrap_or(fallback)
    }

    pub fn embedding_dim(&self) -> usize {
        self.embedding_dim
    }

    pub fn budget_ms(&self) -> u64 {
        self.budget_ms.clamp(500, 300_000)
    }
}

/// Detection entry inside `VisualIndexResultEnvelope.frames[*].detections`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetectionPayload {
    object_class: String,
    confidence: f32,
    bbox: [f32; 4],
    dominant_colors: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    track_id: Option<u64>,
}

impl DetectionPayload {
    pub fn object_class(&self) -> &str {
        &self.object_class
    }

    pub fn confidence(&self) -> f32 {
        self.confidence
    }

    pub fn bbox(&self) -> [f32; 4] {
        self.bbox
    }

    pub fn dominant_colors(&self) -> &[String] {
        &self.dominant_colors
    }

    pub fn track_id(&self) -> Option<u64> {
        self.track_id
    }
}

/// Embedding entry inside `VisualIndexResultEnvelope.frames[*].embeddings`.
///
/// Matches `ServiceRadar.Camera.VisualIndexResultEnvelope`:
/// `:scene` embeddings carry `object_class: null`, `confidence: null`, `bbox: null`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EmbeddingPayload {
    region_kind: String,
    region_index: u32,
    object_class: Option<String>,
    confidence: Option<f32>,
    bbox: Option<[f32; 4]>,
    dominant_colors: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    track_id: Option<u64>,
    embedding: Vec<f32>,
}

impl EmbeddingPayload {
    pub fn region_kind(&self) -> &str {
        &self.region_kind
    }

    pub fn region_index(&self) -> u32 {
        self.region_index
    }

    pub fn object_class(&self) -> Option<&str> {
        self.object_class.as_deref()
    }

    pub fn confidence(&self) -> Option<f32> {
        self.confidence
    }

    pub fn bbox(&self) -> Option<[f32; 4]> {
        self.bbox
    }

    pub fn dominant_colors(&self) -> &[String] {
        &self.dominant_colors
    }

    pub fn track_id(&self) -> Option<u64> {
        self.track_id
    }

    pub fn embedding(&self) -> &[f32] {
        &self.embedding
    }
}

/// Per-track summary entry inside `VisualIndexResultEnvelope.tracks`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackSummaryPayload {
    track_id: u64,
    object_class: String,
    first_seen_offset_ms: u64,
    last_seen_offset_ms: u64,
    dwell_ms: u64,
    frame_count: u32,
    peak_confidence: f32,
}

impl TrackSummaryPayload {
    pub fn track_id(&self) -> u64 {
        self.track_id
    }

    pub fn object_class(&self) -> &str {
        &self.object_class
    }

    pub fn first_seen_offset_ms(&self) -> u64 {
        self.first_seen_offset_ms
    }

    pub fn last_seen_offset_ms(&self) -> u64 {
        self.last_seen_offset_ms
    }

    pub fn dwell_ms(&self) -> u64 {
        self.dwell_ms
    }

    pub fn frame_count(&self) -> u32 {
        self.frame_count
    }

    pub fn peak_confidence(&self) -> f32 {
        self.peak_confidence
    }
}

/// Per-keyframe entry inside `VisualIndexResultEnvelope.frames`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrameResultPayload {
    fragment_sequence: u32,
    media_pts_ns: u64,
    scene_suppressed: bool,
    detections: Vec<DetectionPayload>,
    embeddings: Vec<EmbeddingPayload>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    thumbnail_jpeg_b64: Option<String>,
}

impl FrameResultPayload {
    pub fn fragment_sequence(&self) -> u32 {
        self.fragment_sequence
    }

    pub fn media_pts_ns(&self) -> u64 {
        self.media_pts_ns
    }

    pub fn scene_suppressed(&self) -> bool {
        self.scene_suppressed
    }

    pub fn detections(&self) -> &[DetectionPayload] {
        &self.detections
    }

    pub fn embeddings(&self) -> &[EmbeddingPayload] {
        &self.embeddings
    }

    pub fn thumbnail_jpeg_b64(&self) -> Option<&str> {
        self.thumbnail_jpeg_b64.as_deref()
    }
}

/// A sampled keyframe that was not indexed because it could not be decoded. Recorded in
/// `VisualIndexResultEnvelope.undecodable_keyframes` instead of a fabricated frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UndecodableKeyframePayload {
    fragment_sequence: u32,
    /// One of `unsupported_codec`, `malformed_bitstream`, `limit_exceeded`,
    /// `invalid_container`.
    reason: String,
    codec: String,
}

impl UndecodableKeyframePayload {
    fn new(fragment_sequence: u32, reason: &str, codec: &str) -> Self {
        Self {
            fragment_sequence,
            reason: reason.to_string(),
            codec: codec.to_string(),
        }
    }

    pub fn fragment_sequence(&self) -> u32 {
        self.fragment_sequence
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }

    pub fn codec(&self) -> &str {
        &self.codec
    }
}

/// Result envelope published to `media.results.visual_index.v1` (`VisualIndexResultProjector`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VisualIndexResultEnvelope {
    schema: String,
    schema_version: u32,
    job_id: String,
    catalog_entry_id: String,
    descriptor_sha256: String,
    detector_model_id: String,
    detector_model_version: String,
    embedder_model_id: String,
    embedder_model_version: String,
    model_id: String,
    model_version: String,
    embedding_dim: usize,
    frames: Vec<FrameResultPayload>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tracks: Vec<TrackSummaryPayload>,
    /// Sampled keyframes that could not be decoded; absent when every keyframe decoded.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    undecodable_keyframes: Vec<UndecodableKeyframePayload>,
    /// Optional bounded JFIF JPEG keyframe thumbnail (base64, <= 48 KiB raw) for this block.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    block_thumbnail_jpeg_b64: Option<String>,
}

impl VisualIndexResultEnvelope {
    pub fn schema(&self) -> &str {
        &self.schema
    }

    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }

    pub fn job_id(&self) -> &str {
        &self.job_id
    }

    pub fn catalog_entry_id(&self) -> &str {
        &self.catalog_entry_id
    }

    pub fn descriptor_sha256(&self) -> &str {
        &self.descriptor_sha256
    }

    pub fn detector_model_id(&self) -> &str {
        &self.detector_model_id
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

    pub fn frames(&self) -> &[FrameResultPayload] {
        &self.frames
    }

    pub fn tracks(&self) -> &[TrackSummaryPayload] {
        &self.tracks
    }

    pub fn undecodable_keyframes(&self) -> &[UndecodableKeyframePayload] {
        &self.undecodable_keyframes
    }

    pub fn block_thumbnail_jpeg_b64(&self) -> Option<&str> {
        self.block_thumbnail_jpeg_b64.as_deref()
    }
}

/// Outcome of processing one JetStream visual-index job.
#[derive(Debug, Clone, PartialEq)]
pub enum JobOutcome {
    /// Embeddings published and confirmed on `media.results.visual_index.v1` before ACK.
    Completed(Box<VisualIndexResultEnvelope>),
    /// Control-plane read grant returned `410 Gone` (`recording_gone`); job ACKed cleanly without retry.
    Gone,
}

/// Delivery handle for a pulled JetStream job message (`WPI`, `ACK`, `NAK`).
pub trait JobDelivery: Send + Sync {
    fn payload(&self) -> &[u8];

    fn send_in_progress(&self) -> impl Future<Output = Result<(), MediaWorkerError>> + Send;

    fn ack_completed(&self) -> impl Future<Output = Result<(), MediaWorkerError>> + Send;

    fn nak_failed(&self) -> impl Future<Output = Result<(), MediaWorkerError>> + Send;
}

/// Publisher confirming durable JetStream persistence of `media.results.visual_index.v1`
/// BEFORE the source job message is acknowledged.
pub trait ResultPublisher: Send + Sync {
    fn publish_visual_result(
        &self,
        msg_id: &str,
        envelope: &VisualIndexResultEnvelope,
    ) -> impl Future<Output = Result<(), MediaWorkerError>> + Send;

    fn publish_vantage_result(
        &self,
        msg_id: &str,
        envelope: &VantageResultEnvelope,
    ) -> impl Future<Output = Result<(), MediaWorkerError>> + Send;

    fn publish_telemetry_snapshot(
        &self,
        payload_json: &[u8],
    ) -> impl Future<Output = Result<(), MediaWorkerError>> + Send;
}

/// Interactive NATS request-reply payload sent by `ServiceRadar.Camera.SemanticSearch`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextEmbedRpcRequest {
    #[serde(default)]
    schema: Option<String>,
    query: String,
    model_id: String,
    model_version: String,
    expected_dim: usize,
    #[serde(default = "default_text_deadline_ms")]
    deadline_ms: u64,
}

impl TextEmbedRpcRequest {
    pub fn new(
        query: impl Into<String>,
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        expected_dim: usize,
        deadline_ms: u64,
    ) -> Self {
        Self {
            schema: Some(VISUAL_TEXT_EMBED_RPC_PREFIX.to_string()),
            query: query.into(),
            model_id: model_id.into(),
            model_version: model_version.into(),
            expected_dim,
            deadline_ms,
        }
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    pub fn model_version(&self) -> &str {
        &self.model_version
    }

    pub fn expected_dim(&self) -> usize {
        self.expected_dim
    }

    pub fn deadline_ms(&self) -> u64 {
        self.deadline_ms.clamp(10, 250)
    }
}

/// Interactive NATS request-reply response consumed by `ServiceRadar.Camera.SemanticSearch`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextEmbedRpcResponse {
    schema: String,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    embedding_dim: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    embedding: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl TextEmbedRpcResponse {
    pub fn ok(models: &ModelPinConfig, embedding: Vec<f32>) -> Self {
        Self {
            schema: VISUAL_TEXT_EMBED_RPC_PREFIX.to_string(),
            status: "ok".to_string(),
            model_id: Some(models.embedder_model_id().to_string()),
            model_version: Some(models.embedder_model_version().to_string()),
            embedding_dim: Some(models.embedding_dim()),
            embedding: Some(embedding),
            error: None,
        }
    }

    pub fn error(reason: impl Into<String>) -> Self {
        Self {
            schema: VISUAL_TEXT_EMBED_RPC_PREFIX.to_string(),
            status: "error".to_string(),
            model_id: None,
            model_version: None,
            embedding_dim: None,
            embedding: None,
            error: Some(reason.into()),
        }
    }

    pub fn status(&self) -> &str {
        &self.status
    }

    pub fn embedding(&self) -> Option<&[f32]> {
        self.embedding.as_deref()
    }

    pub fn error_reason(&self) -> Option<&str> {
        self.error.as_deref()
    }
}

/// Builds the canonical NATS RPC subject `media.rpc.visual_text_embed.v1.<model_id>.<model_version>`.
pub fn text_embed_rpc_subject(models: &ModelPinConfig) -> String {
    format!(
        "{}.{}.{}",
        VISUAL_TEXT_EMBED_RPC_PREFIX,
        models.embedder_model_id(),
        models.embedder_model_version()
    )
}

/// Reserved interactive text-embedding lane (`2.5`), isolated on its own semaphore
/// from bulk `media.jobs.visual_index.v1` processing.
#[derive(Clone)]
pub(crate) struct TextEmbedService {
    models: ModelPinConfig,
    backend: Arc<dyn InferenceBackend>,
    semaphore: Arc<Semaphore>,
    metrics: Arc<WorkerMetrics>,
}

const WARMUP_TEXT_EMBED_DEADLINE_MS: u64 = 2_000;

impl TextEmbedService {
    pub(crate) fn new(
        models: ModelPinConfig,
        backend: Arc<dyn InferenceBackend>,
        concurrency: usize,
        metrics: Arc<WorkerMetrics>,
    ) -> Self {
        Self {
            models,
            backend,
            semaphore: Arc::new(Semaphore::new(concurrency.max(1))),
            metrics,
        }
    }

    /// Evaluates a JSON `TextEmbedRpcRequest` within `<= 250 ms` on reserved capacity.
    pub(crate) async fn handle_rpc_payload(&self, raw_payload: &[u8]) -> TextEmbedRpcResponse {
        self.handle_rpc_payload_with_max_deadline(raw_payload, 250)
            .await
    }

    async fn handle_rpc_payload_with_max_deadline(
        &self,
        raw_payload: &[u8],
        max_deadline_ms: u64,
    ) -> TextEmbedRpcResponse {
        let req: TextEmbedRpcRequest = match serde_json::from_slice(raw_payload) {
            Ok(parsed) => parsed,
            Err(_) => return TextEmbedRpcResponse::error("invalid_json_request"),
        };

        if let Some(schema) = req.schema.as_deref()
            && schema != VISUAL_TEXT_EMBED_RPC_PREFIX
        {
            return TextEmbedRpcResponse::error("unsupported_schema");
        }

        let expected_dim = self.backend.info().embedding_dim();
        if req.model_id() != self.models.embedder_model_id()
            || req.model_version() != self.models.embedder_model_version()
            || req.expected_dim() != expected_dim
        {
            return TextEmbedRpcResponse::error("model_version_or_dim_mismatch");
        }

        let effective_deadline_ms = if max_deadline_ms <= 250 {
            req.deadline_ms()
        } else {
            req.deadline_ms.clamp(10, max_deadline_ms)
        };
        let deadline = Duration::from_millis(effective_deadline_ms);
        let started = Instant::now();
        let sem = Arc::clone(&self.semaphore);

        let Ok(Ok(permit)) = timeout(deadline, sem.acquire_owned()).await else {
            return TextEmbedRpcResponse::error("text_embed_capacity_timeout");
        };
        let _inflight = self.metrics.guard_inflight_text_embed();
        let remaining = deadline.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            drop(permit);
            return TextEmbedRpcResponse::error("text_embed_deadline_exceeded");
        }

        let query = req.query().to_string();
        let backend = Arc::clone(&self.backend);
        let compute_res = timeout(
            remaining,
            tokio::task::spawn_blocking(move || backend.encode_text(&query)),
        )
        .await;
        drop(permit);

        match compute_res {
            Ok(Ok(Ok(vec))) => {
                self.metrics
                    .observe_text_embed_latency(started.elapsed().as_secs_f64());
                TextEmbedRpcResponse::ok(&self.models, vec)
            }
            Ok(Ok(Err(err))) => TextEmbedRpcResponse::error(err.error_class()),
            _ => TextEmbedRpcResponse::error("text_embed_execution_failed"),
        }
    }

    /// Exercises the full async RPC path (`serde_json`, semaphore, `tokio::task::spawn_blocking`,
    /// and `InferenceBackend::encode_text`) before readiness turns `200 OK`, using a generous
    /// admission deadline (`2_000 ms`) so CPU-only `candle` runs do not falsely fail startup.
    pub(crate) async fn warmup_rpc(&self) -> Result<(), MediaWorkerError> {
        let expected_dim = self.backend.info().embedding_dim();
        let req = TextEmbedRpcRequest::new(
            "synthetic rpc warmup query",
            self.models.embedder_model_id(),
            self.models.embedder_model_version(),
            expected_dim,
            WARMUP_TEXT_EMBED_DEADLINE_MS,
        );
        let payload = serde_json::to_vec(&req).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed serializing text-embed RPC warmup request: {err}"
            ))
        })?;
        let resp = self
            .handle_rpc_payload_with_max_deadline(&payload, WARMUP_TEXT_EMBED_DEADLINE_MS)
            .await;
        if resp.status() != "ok" {
            return Err(MediaWorkerError::inference_failed(format!(
                "text-embed RPC warmup failed: {}",
                resp.error_reason().unwrap_or("unknown_error")
            )));
        }
        serde_json::to_vec(&resp).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed serializing text-embed RPC warmup response: {err}"
            ))
        })?;
        Ok(())
    }
}

pub(crate) async fn warmup_text_embed_rpc(
    models: &ModelPinConfig,
    backend: Arc<dyn InferenceBackend>,
    concurrency: usize,
) -> Result<(), MediaWorkerError> {
    let service = TextEmbedService::new(
        models.clone(),
        backend,
        concurrency,
        Arc::new(WorkerMetrics::new()),
    );
    service.warmup_rpc().await
}

/// Core visual-indexing worker engine (`2.4`, `2.5`) coordinating:
/// - `index_concurrency` semaphore admission (completely separate from `TextEmbedService`);
/// - periodic `AckKind::Progress` (`WPI`) heartbeats while decoding/inferring;
/// - execution-time read grant acquisition (`410 Gone` clean ACK skip);
/// - SHA-256 verification + CMAF keyframe decode + Stage 1/Stage 2 pipeline;
/// - confirmed JetStream publication to `media.results.visual_index.v1` **before** `ACK`.
pub struct VisualIndexProcessor<G, S, P> {
    models: ModelPinConfig,
    pipeline: VisionPipeline,
    index_semaphore: Arc<Semaphore>,
    wpi_interval: Duration,
    otel_endpoint: String,
    grant_client: Arc<G>,
    fragment_store: Arc<S>,
    publisher: Arc<P>,
    metrics: Arc<WorkerMetrics>,
    keyframe_decoder: Arc<dyn KeyframeDecoder>,
}

impl<G, S, P> Clone for VisualIndexProcessor<G, S, P> {
    fn clone(&self) -> Self {
        Self {
            models: self.models.clone(),
            pipeline: self.pipeline.clone(),
            index_semaphore: Arc::clone(&self.index_semaphore),
            wpi_interval: self.wpi_interval,
            otel_endpoint: self.otel_endpoint.clone(),
            grant_client: Arc::clone(&self.grant_client),
            fragment_store: Arc::clone(&self.fragment_store),
            publisher: Arc::clone(&self.publisher),
            metrics: Arc::clone(&self.metrics),
            keyframe_decoder: Arc::clone(&self.keyframe_decoder),
        }
    }
}

impl<G, S, P> VisualIndexProcessor<G, S, P>
where
    G: GrantClient + 'static,
    S: FragmentStore + 'static,
    P: ResultPublisher + 'static,
{
    pub fn with_backend(
        config: &WorkerConfig,
        backend: Arc<dyn InferenceBackend>,
        grant_client: G,
        fragment_store: S,
        publisher: P,
        metrics: Arc<WorkerMetrics>,
    ) -> Self {
        Self {
            models: config.models().clone(),
            pipeline: VisionPipeline::with_backend(
                config.models().clone(),
                config.skip_unchanged_empty_scenes(),
                backend,
            )
            .with_tracking(config.tracker_mode(), config.dedup_track_crops()),
            index_semaphore: Arc::new(Semaphore::new(config.index_concurrency().max(1))),
            wpi_interval: Duration::from_secs(15),
            otel_endpoint: config.otel_endpoint().to_string(),
            grant_client: Arc::new(grant_client),
            fragment_store: Arc::new(fragment_store),
            publisher: Arc::new(publisher),
            metrics,
            keyframe_decoder: Arc::new(DefaultKeyframeDecoder::new()),
        }
    }

    /// Replaces the keyframe decoder (the default is [`DefaultKeyframeDecoder`]).
    pub fn with_keyframe_decoder(mut self, decoder: Arc<dyn KeyframeDecoder>) -> Self {
        self.keyframe_decoder = decoder;
        self
    }

    pub fn with_wpi_interval(mut self, interval: Duration) -> Self {
        self.wpi_interval = interval.max(Duration::from_millis(5));
        self
    }

    pub fn index_semaphore(&self) -> &Arc<Semaphore> {
        &self.index_semaphore
    }

    pub fn metrics(&self) -> &Arc<WorkerMetrics> {
        &self.metrics
    }

    /// Processes a single pulled JetStream job delivery end-to-end, enforcing
    /// periodic `WPI` heartbeats and strict publish-before-ACK ordering.
    pub async fn process_delivery<D: JobDelivery + 'static>(
        &self,
        delivery: Arc<D>,
    ) -> Result<JobOutcome, MediaWorkerError> {
        let permit = Arc::clone(&self.index_semaphore)
            .acquire_owned()
            .await
            .map_err(|_| MediaWorkerError::nats_error("index_concurrency semaphore closed"))?;
        let _inflight = self.metrics.guard_inflight_index_job();

        let job: VisualIndexJobEnvelope = match serde_json::from_slice(delivery.payload()) {
            Ok(parsed) => parsed,
            Err(err) => {
                self.metrics.inc_jobs_failed();
                let _ = delivery.nak_failed().await;
                return Err(MediaWorkerError::invalid_job_envelope(format!(
                    "malformed visual index job JSON: {err}"
                )));
            }
        };

        let wpi_guard = spawn_wpi_heartbeat(
            Arc::clone(&delivery),
            self.wpi_interval,
            Duration::from_millis(job.budget_ms()),
        );

        let permit = Arc::new(permit);
        let execution_res = self.execute_job(&job, Arc::clone(&permit)).await;
        wpi_guard.stop().await;

        match execution_res {
            Ok(JobExecution::Gone) => {
                self.metrics.inc_jobs_gone();
                delivery.ack_completed().await?;
                self.emit_telemetry_best_effort().await;
                Ok(JobOutcome::Gone)
            }
            Ok(JobExecution::ReadyResult(envelope)) => {
                debug!(job_id = job.job_id(), totals_by_reason = ?{
                    let mut totals = BTreeMap::new();
                    for entry in envelope.undecodable_keyframes() {
                        *totals.entry(entry.reason()).or_insert(0usize) += 1;
                    }
                    totals
                }, "keyframe decode summary");
                // CRITICAL INVARIANT (`2.5`): Confirm durable JetStream publish of
                // `media.results.visual_index.v1` BEFORE calling `ack_completed`!
                let msg_id = format!("visual-result:{}", job.job_id());
                if let Err(pub_err) = self
                    .publisher
                    .publish_visual_result(&msg_id, &envelope)
                    .await
                {
                    self.metrics.inc_jobs_failed();
                    let _ = delivery.nak_failed().await;
                    return Err(pub_err);
                }

                delivery.ack_completed().await?;
                self.metrics.inc_jobs_completed();
                self.emit_telemetry_best_effort().await;
                Ok(JobOutcome::Completed(envelope))
            }
            Err(err) => {
                self.metrics.inc_jobs_failed();
                if is_terminal_non_retryable(&err) {
                    // Schema or digest mismatch cannot self-heal on immediate tight-loop NAK;
                    // NAK lets JetStream increment delivery count toward MaxDeliver reconciliation.
                    let _ = delivery.nak_failed().await;
                } else {
                    let _ = delivery.nak_failed().await;
                }
                self.emit_telemetry_best_effort().await;
                Err(err)
            }
        }
    }

    async fn execute_job(
        &self,
        job: &VisualIndexJobEnvelope,
        permit: Arc<tokio::sync::OwnedSemaphorePermit>,
    ) -> Result<JobExecution, MediaWorkerError> {
        self.validate_job_compatibility(job)?;

        let grant_req = ReadGrantRequest::new(
            job.job_id(),
            job.catalog_entry_id(),
            job.descriptor_sha256(),
        );
        let plan = match self.grant_client.acquire_read_grant(&grant_req).await? {
            GrantResolution::Gone => return Ok(JobExecution::Gone),
            GrantResolution::Admitted(plan) => plan,
        };

        let verified_block = self.fragment_store.fetch_verified_block(&plan).await?;
        let processor = self.clone();
        let job = job.clone();
        let dispatch = tracing::dispatcher::get_default(Clone::clone);
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let _subscriber = tracing::dispatcher::set_default(&dispatch);
            processor.index_block(&job, &verified_block)
        })
        .await
        .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?
    }

    fn index_block(
        &self,
        job: &VisualIndexJobEnvelope,
        verified_block: &VerifiedKeyframeBlock,
    ) -> Result<JobExecution, MediaWorkerError> {
        let (codec, init_seg) = parse_init_segment_with_codec(verified_block.init_bytes());
        let init_seg = init_seg.and_then(|init| {
            self.keyframe_decoder.validate_init(&init)?;
            Ok(init)
        });
        let codec = codec.map_or("unknown", VideoCodec::as_str);
        let mut sampled_frames = Vec::with_capacity(verified_block.fragments().len());
        let mut undecodable_keyframes = Vec::new();
        let mut base_pts_ns = 0;
        for (index, frag) in verified_block.fragments().iter().enumerate() {
            let (container_pts_ns, decoded) = match &init_seg {
                Ok(init) => {
                    let (pts, sample) = parse_timed_fragment(frag.bytes(), init);
                    (
                        pts,
                        sample.map_err(|err| err.error_class()).and_then(|parsed| {
                            self.keyframe_decoder
                                .decode_keyframe(init, &parsed)
                                .map_err(|err| err.reason())
                        }),
                    )
                }
                Err(error) => (0, Err(error.error_class())),
            };
            let media_pts_ns = if frag.start_ns() == 0 {
                container_pts_ns
            } else {
                frag.start_ns()
            };
            if index == 0 {
                base_pts_ns = media_pts_ns;
            }
            let frame = match decoded {
                Ok(frame) => {
                    self.metrics.inc_keyframes_decoded(1);
                    Some(frame)
                }
                Err(reason) => {
                    self.metrics.inc_keyframes_undecodable(reason);
                    undecodable_keyframes.push(UndecodableKeyframePayload::new(
                        frag.sequence(),
                        reason,
                        codec,
                    ));
                    None
                }
            };
            sampled_frames.push((frag.sequence(), media_pts_ns, frame));
        }

        let slots = sampled_frames
            .iter()
            .map(|(_, pts, frame)| (pts.saturating_sub(base_pts_ns) / 1_000_000, frame.as_ref()));
        let clip_analysis = self
            .pipeline
            .process_sampled_keyframes_with_roi(slots, job.roi_grid())?;
        for &secs in clip_analysis.stage1_latencies_secs() {
            self.metrics.observe_stage1_latency(secs);
        }
        for &secs in clip_analysis.stage2_latencies_secs() {
            self.metrics.observe_stage2_latency(secs);
        }

        let block_thumbnail = clip_analysis.block_thumbnail_jpeg_b64().map(str::to_string);
        let thumbnail_frame_order = clip_analysis.thumbnail_frame_order().to_vec();
        let (frame_analyses, track_summaries) = clip_analysis.into_parts();
        let mut frame_payloads = Vec::with_capacity(frame_analyses.len());
        let mut frame_thumbnails = Vec::with_capacity(frame_analyses.len());
        for ((sequence, media_pts_ns, _), analysis) in sampled_frames
            .into_iter()
            .filter(|(_, _, frame)| frame.is_some())
            .zip(frame_analyses)
        {
            let det_payloads = analysis
                .detections()
                .iter()
                .map(|d| DetectionPayload {
                    object_class: d.object_class().as_str().to_string(),
                    confidence: d.confidence(),
                    bbox: d.bbox_norm(),
                    dominant_colors: d.dominant_colors().to_vec(),
                    track_id: d.track_id(),
                })
                .collect();

            let emb_payloads = analysis
                .embeddings()
                .iter()
                .map(|e| EmbeddingPayload {
                    region_kind: e.region_kind().to_string(),
                    region_index: e.region_index(),
                    object_class: e.object_class().map(str::to_string),
                    confidence: e.confidence(),
                    bbox: e.bbox_norm(),
                    dominant_colors: e.dominant_colors().to_vec(),
                    track_id: e.track_id(),
                    embedding: e.embedding().to_vec(),
                })
                .collect();

            frame_thumbnails.push(analysis.thumbnail_jpeg_b64().map(str::to_string));
            frame_payloads.push(FrameResultPayload {
                fragment_sequence: sequence,
                media_pts_ns,
                scene_suppressed: analysis.scene_suppressed(),
                detections: det_payloads,
                embeddings: emb_payloads,
                thumbnail_jpeg_b64: None,
            });
        }

        let track_payloads: Vec<TrackSummaryPayload> = track_summaries
            .into_iter()
            .map(|t| TrackSummaryPayload {
                track_id: t.track_id(),
                object_class: t.object_class().as_str().to_string(),
                first_seen_offset_ms: t.first_seen_offset_ms(),
                last_seen_offset_ms: t.last_seen_offset_ms(),
                dwell_ms: t.dwell_ms(),
                frame_count: t.frame_count(),
                peak_confidence: t.peak_confidence(),
            })
            .collect();

        let det_id = job
            .resolved_detector_model_id(self.models.detector_model_id())
            .to_string();
        let det_ver = job
            .resolved_detector_model_version(self.models.detector_model_version())
            .to_string();
        let emb_id = self.models.embedder_model_id().to_string();
        let emb_ver = self.models.embedder_model_version().to_string();

        let mut envelope = VisualIndexResultEnvelope {
            schema: VISUAL_INDEX_RESULTS_SUBJECT.to_string(),
            schema_version: 1,
            job_id: job.job_id().to_string(),
            catalog_entry_id: job.catalog_entry_id().to_string(),
            descriptor_sha256: job.descriptor_sha256().to_string(),
            detector_model_id: det_id,
            detector_model_version: det_ver,
            embedder_model_id: emb_id.clone(),
            embedder_model_version: emb_ver.clone(),
            model_id: emb_id,
            model_version: emb_ver,
            embedding_dim: self.models.embedding_dim(),
            frames: frame_payloads,
            tracks: track_payloads,
            undecodable_keyframes,
            block_thumbnail_jpeg_b64: None,
        };
        attach_envelope_thumbnails_within_ceiling(
            &mut envelope,
            block_thumbnail,
            frame_thumbnails,
            &thumbnail_frame_order,
            MAX_RESULT_ENVELOPE_JSON_BYTES,
        )?;

        Ok(JobExecution::ReadyResult(Box::new(envelope)))
    }

    fn validate_job_compatibility(
        &self,
        job: &VisualIndexJobEnvelope,
    ) -> Result<(), MediaWorkerError> {
        if job.schema_version != 1 {
            return Err(MediaWorkerError::invalid_job_envelope(format!(
                "unsupported job schema_version {}",
                job.schema_version
            )));
        }
        if job.embedding_dim() != self.models.embedding_dim() {
            return Err(MediaWorkerError::invalid_job_envelope(format!(
                "job embedding_dim {} mismatches worker embedding_dim {}",
                job.embedding_dim(),
                self.models.embedding_dim()
            )));
        }
        if let Some(req_model) = job.resolved_embedder_model_id()
            && req_model != self.models.embedder_model_id()
        {
            return Err(MediaWorkerError::invalid_job_envelope(format!(
                "job embedder_model_id '{req_model}' mismatches worker '{}'",
                self.models.embedder_model_id()
            )));
        }
        if let Some(req_ver) = job.resolved_embedder_model_version()
            && req_ver != self.models.embedder_model_version()
        {
            return Err(MediaWorkerError::invalid_job_envelope(format!(
                "job embedder_model_version '{req_ver}' mismatches worker '{}'",
                self.models.embedder_model_version()
            )));
        }
        Ok(())
    }

    async fn emit_telemetry_best_effort(&self) {
        let snap = self.metrics.snapshot(
            &self.otel_endpoint,
            self.models.embedder_model_id(),
            self.models.embedder_model_version(),
        );
        if let Ok(encoded) = serde_json::to_vec(&snap) {
            let _ = self.publisher.publish_telemetry_snapshot(&encoded).await;
        }
    }
}

struct CountingWriter(usize);

impl std::io::Write for CountingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0 = self.0.saturating_add(buf.len());
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn serialized_json_len<T: Serialize>(value: &T) -> Result<usize, MediaWorkerError> {
    let mut counter = CountingWriter(0);
    serde_json::to_writer(&mut counter, value).map_err(|err| {
        MediaWorkerError::nats_error(format!("failed measuring visual result JSON size: {err}"))
    })?;
    Ok(counter.0)
}

fn attach_envelope_thumbnails_within_ceiling(
    envelope: &mut VisualIndexResultEnvelope,
    block_thumbnail: Option<String>,
    mut frame_thumbnails: Vec<Option<String>>,
    thumbnail_frame_order: &[usize],
    max_envelope_json_bytes: usize,
) -> Result<(), MediaWorkerError> {
    const BLOCK_THUMB_JSON_OVERHEAD: usize = r#","block_thumbnail_jpeg_b64":"""#.len();
    const FRAME_THUMB_JSON_OVERHEAD: usize = r#","thumbnail_jpeg_b64":"""#.len();

    let base_len = serialized_json_len(envelope)?;
    let mut headroom = max_envelope_json_bytes.saturating_sub(base_len);

    if let Some(block_b64) = block_thumbnail {
        let block_cost = BLOCK_THUMB_JSON_OVERHEAD.saturating_add(block_b64.len());
        if block_cost <= headroom {
            headroom -= block_cost;
            envelope.block_thumbnail_jpeg_b64 = Some(block_b64);
        } else {
            return Ok(());
        }
    }

    for &frame_idx in thumbnail_frame_order {
        let Some(frame_b64) = frame_thumbnails.get_mut(frame_idx).and_then(Option::take) else {
            continue;
        };
        let frame_cost = FRAME_THUMB_JSON_OVERHEAD.saturating_add(frame_b64.len());
        if frame_cost > headroom {
            break;
        }
        headroom -= frame_cost;
        if let Some(frame_payload) = envelope.frames.get_mut(frame_idx) {
            frame_payload.thumbnail_jpeg_b64 = Some(frame_b64);
        }
    }

    Ok(())
}

enum JobExecution {
    Gone,
    ReadyResult(Box<VisualIndexResultEnvelope>),
}

fn is_terminal_non_retryable(err: &MediaWorkerError) -> bool {
    matches!(
        err.kind(),
        MediaWorkerErrorKind::InvalidJobEnvelope(_)
            | MediaWorkerErrorKind::Integrity(IntegrityError { .. })
    )
}

pub(crate) struct WpiHeartbeatHandle {
    stop_tx: Option<tokio::sync::oneshot::Sender<()>>,
    join: tokio::task::JoinHandle<()>,
}

impl WpiHeartbeatHandle {
    pub(crate) async fn stop(mut self) {
        if let Some(tx) = self.stop_tx.take() {
            let _ = tx.send(());
        }
        let _ = self.join.await;
    }
}

pub(crate) fn spawn_wpi_heartbeat<D: JobDelivery + 'static>(
    delivery: Arc<D>,
    interval: Duration,
    max_budget: Duration,
) -> WpiHeartbeatHandle {
    let (stop_tx, mut stop_rx) = tokio::sync::oneshot::channel();
    let deadline = Instant::now() + max_budget;
    let join = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        // Skip the immediate tick at t=0; first WPI fires after `interval`.
        ticker.tick().await;
        loop {
            tokio::select! {
                _ = &mut stop_rx => break,
                _ = ticker.tick() => {
                    if Instant::now() >= deadline {
                        break;
                    }
                    if let Err(err) = delivery.send_in_progress().await {
                        debug!("WPI progress heartbeat failed: {err}");
                        break;
                    }
                }
            }
        }
    });
    WpiHeartbeatHandle {
        stop_tx: Some(stop_tx),
        join,
    }
}

// ============================================================================
// Live NATS + JetStream Runtime Wiring
// ============================================================================

/// JetStream message wrapper implementing `JobDelivery`.
pub struct JetStreamJobDelivery {
    msg: jetstream::Message,
}

impl JetStreamJobDelivery {
    pub fn new(msg: jetstream::Message) -> Self {
        Self { msg }
    }
}

impl JobDelivery for JetStreamJobDelivery {
    fn payload(&self) -> &[u8] {
        self.msg.payload.as_ref()
    }

    async fn send_in_progress(&self) -> Result<(), MediaWorkerError> {
        self.msg
            .ack_with(AckKind::Progress)
            .await
            .map_err(|err| MediaWorkerError::nats_error(format!("JetStream WPI failed: {err}")))
    }

    async fn ack_completed(&self) -> Result<(), MediaWorkerError> {
        self.msg
            .ack()
            .await
            .map_err(|err| MediaWorkerError::nats_error(format!("JetStream ACK failed: {err}")))
    }

    async fn nak_failed(&self) -> Result<(), MediaWorkerError> {
        self.msg
            .ack_with(AckKind::Nak(None))
            .await
            .map_err(|err| MediaWorkerError::nats_error(format!("JetStream NAK failed: {err}")))
    }
}

/// Live NATS JetStream publisher confirming `PublishAckFuture` before returning.
#[derive(Clone)]
pub struct JetStreamResultPublisher {
    js: jetstream::Context,
    cert_policy: Option<Arc<serviceradar_cert_policy::nats::Guard>>,
    publish_timeout: Duration,
}

impl JetStreamResultPublisher {
    pub fn new(
        js: jetstream::Context,
        cert_policy: Option<Arc<serviceradar_cert_policy::nats::Guard>>,
        publish_timeout: Duration,
    ) -> Self {
        Self {
            js,
            cert_policy,
            publish_timeout,
        }
    }
}

impl ResultPublisher for JetStreamResultPublisher {
    async fn publish_visual_result(
        &self,
        msg_id: &str,
        envelope: &VisualIndexResultEnvelope,
    ) -> Result<(), MediaWorkerError> {
        if let Some(guard) = &self.cert_policy {
            guard
                .ensure_authorized()
                .map_err(|err| MediaWorkerError::nats_error(err.to_string()))?;
        }

        let payload = serde_json::to_vec(envelope).map_err(|err| {
            MediaWorkerError::nats_error(format!("failed serializing visual result JSON: {err}"))
        })?;

        let mut headers = HeaderMap::new();
        headers.insert("Nats-Msg-Id", msg_id);

        timeout(self.publish_timeout, async {
            let ack_fut = self
                .js
                .publish_with_headers(VISUAL_INDEX_RESULTS_SUBJECT, headers, payload.into())
                .await
                .map_err(|err| {
                    MediaWorkerError::nats_error(format!(
                        "JetStream publish to {VISUAL_INDEX_RESULTS_SUBJECT} failed: {err}"
                    ))
                })?;
            ack_fut.await.map_err(|err| {
                MediaWorkerError::nats_error(format!(
                    "JetStream pub-ack for {VISUAL_INDEX_RESULTS_SUBJECT} failed: {err}"
                ))
            })?;
            Ok::<(), MediaWorkerError>(())
        })
        .await
        .map_err(|_| {
            MediaWorkerError::deadline_exceeded(format!(
                "JetStream publish timeout on {VISUAL_INDEX_RESULTS_SUBJECT}"
            ))
        })??;

        Ok(())
    }

    async fn publish_vantage_result(
        &self,
        msg_id: &str,
        envelope: &VantageResultEnvelope,
    ) -> Result<(), MediaWorkerError> {
        if let Some(guard) = &self.cert_policy {
            guard
                .ensure_authorized()
                .map_err(|err| MediaWorkerError::nats_error(err.to_string()))?;
        }

        let payload = serde_json::to_vec(envelope).map_err(|err| {
            MediaWorkerError::nats_error(format!("failed serializing vantage result JSON: {err}"))
        })?;
        if payload.len() > MAX_VANTAGE_RESULT_ENVELOPE_BYTES {
            return Err(MediaWorkerError::inference_failed(format!(
                "VantageResultEnvelope payload {} exceeds {} bytes",
                payload.len(),
                MAX_VANTAGE_RESULT_ENVELOPE_BYTES
            )));
        }

        let mut headers = HeaderMap::new();
        headers.insert("Nats-Msg-Id", msg_id);

        timeout(self.publish_timeout, async {
            let ack_fut = self
                .js
                .publish_with_headers(VANTAGE_RESULTS_SUBJECT, headers, payload.into())
                .await
                .map_err(|err| {
                    MediaWorkerError::nats_error(format!(
                        "JetStream publish to {VANTAGE_RESULTS_SUBJECT} failed: {err}"
                    ))
                })?;
            ack_fut.await.map_err(|err| {
                MediaWorkerError::nats_error(format!(
                    "JetStream pub-ack for {VANTAGE_RESULTS_SUBJECT} failed: {err}"
                ))
            })?;
            Ok::<(), MediaWorkerError>(())
        })
        .await
        .map_err(|_| {
            MediaWorkerError::deadline_exceeded(format!(
                "JetStream publish timeout on {VANTAGE_RESULTS_SUBJECT}"
            ))
        })??;

        Ok(())
    }

    async fn publish_telemetry_snapshot(
        &self,
        payload_json: &[u8],
    ) -> Result<(), MediaWorkerError> {
        let payload = bytes::Bytes::copy_from_slice(payload_json);
        if let Ok(ack_fut) = self
            .js
            .publish(MEDIA_WORKER_TELEMETRY_SUBJECT, payload)
            .await
        {
            let _ = timeout(Duration::from_secs(2), ack_fut).await;
        }
        Ok(())
    }
}

/// Spawns the reserved NATS request-reply subscriber on
/// `media.rpc.visual_text_embed.v1.<model_id>.<model_version>`.
pub(crate) async fn spawn_nats_text_embed_responder(
    client: Client,
    worker: &AdmittedWorker,
    metrics: Arc<WorkerMetrics>,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) -> Result<tokio::task::JoinHandle<()>, MediaWorkerError> {
    let models = worker.config.models();
    let subject = text_embed_rpc_subject(models);
    warmup_text_embed_rpc(
        models,
        Arc::clone(&worker.backend),
        worker.config.text_embed_concurrency(),
    )
    .await?;
    let service = TextEmbedService::new(
        models.clone(),
        Arc::clone(&worker.backend),
        worker.config.text_embed_concurrency(),
        metrics,
    );
    let mut subscription = client
        .queue_subscribe(subject.clone(), VISUAL_TEXT_EMBED_QUEUE_GROUP.to_string())
        .await
        .map_err(|err| {
            MediaWorkerError::nats_error(format!(
                "failed subscribing to text-embed RPC subject '{subject}': {err}"
            ))
        })?;
    client.flush().await.map_err(|err| {
        MediaWorkerError::nats_error(format!(
            "failed flushing text-embed RPC subscription '{subject}': {err}"
        ))
    })?;

    info!(subject = %subject, "started reserved interactive text-embedder NATS responder");

    let handle = tokio::spawn(async move {
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                }
                maybe_msg = subscription.next() => {
                    let Some(msg) = maybe_msg else { break; };
                    let Some(reply_subject) = msg.reply else { continue; };
                    let svc = service.clone();
                    let nats = client.clone();
                    tokio::spawn(async move {
                        let resp = svc.handle_rpc_payload(&msg.payload).await;
                        if let Ok(bytes) = serde_json::to_vec(&resp) {
                            let _ = nats.publish(reply_subject, bytes.into()).await;
                        }
                    });
                }
            }
        }
    });

    Ok(handle)
}

pub struct AdmittedWorker {
    config: WorkerConfig,
    pub(crate) backend: Arc<dyn InferenceBackend>,
}

pub async fn load_and_admit_worker(
    config: WorkerConfig,
) -> Result<(AdmittedWorker, CapabilityManifest), MediaWorkerError> {
    admit_worker(config, build_inference_backend).await
}

async fn admit_worker(
    config: WorkerConfig,
    load: impl FnOnce(&WorkerConfig) -> Result<Arc<dyn InferenceBackend>, MediaWorkerError>
    + Send
    + 'static,
) -> Result<(AdmittedWorker, CapabilityManifest), MediaWorkerError> {
    let (worker, manifest) = tokio::task::spawn_blocking(move || {
        let backend = load(&config)?;
        let manifest = verify_startup_capabilities_with_backend(
            &config,
            &SystemGpuEnvironmentProbe,
            Arc::clone(&backend),
        )?;
        Ok::<_, MediaWorkerError>((AdmittedWorker { config, backend }, manifest))
    })
    .await
    .map_err(|err| {
        MediaWorkerError::inference_failed(format!("startup admission task failed: {err}"))
    })??;

    warmup_text_embed_rpc(
        worker.config.models(),
        Arc::clone(&worker.backend),
        worker.config.text_embed_concurrency(),
    )
    .await?;

    Ok((worker, manifest))
}

/// Connects to NATS (with optional mTLS + `serviceradar-cert-policy`) and runs
/// both the reserved interactive text-embedder responder and the JetStream
/// visual-index pull loop until `shutdown` signals termination.
pub async fn run_nats_worker_loops(
    config: WorkerConfig,
    metrics: Arc<WorkerMetrics>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) -> Result<(), MediaWorkerError> {
    let (worker, _) = load_and_admit_worker(config).await?;
    run_admitted_nats_worker(worker, metrics, shutdown).await
}

/// Runs the NATS worker loops using a pre-initialized `InferenceBackend`.
pub async fn run_nats_worker_loops_with_backend(
    config: WorkerConfig,
    backend: Arc<dyn InferenceBackend>,
    metrics: Arc<WorkerMetrics>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) -> Result<(), MediaWorkerError> {
    let (worker, _) = admit_worker(config, move |_| Ok(backend)).await?;
    run_admitted_nats_worker(worker, metrics, shutdown).await
}

pub async fn run_admitted_nats_worker(
    worker: AdmittedWorker,
    metrics: Arc<WorkerMetrics>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) -> Result<(), MediaWorkerError> {
    run_admitted_nats_worker_inner(worker, metrics, shutdown, None).await
}

/// Connects to NATS, ensures JetStream streams, subscribes and warms up the interactive
/// text-embedding RPC responder, and only then transitions `/readyz` to `200 OK` before
/// entering the visual-index pull loop.
pub async fn run_admitted_nats_worker_with_readiness(
    worker: AdmittedWorker,
    metrics: Arc<WorkerMetrics>,
    shutdown: tokio::sync::watch::Receiver<bool>,
    readiness: ReadinessState,
    manifest: CapabilityManifest,
) -> Result<(), MediaWorkerError> {
    run_admitted_nats_worker_inner(worker, metrics, shutdown, Some((readiness, manifest))).await
}

async fn run_admitted_nats_worker_inner(
    worker: AdmittedWorker,
    metrics: Arc<WorkerMetrics>,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
    ready_state: Option<(ReadinessState, CapabilityManifest)>,
) -> Result<(), MediaWorkerError> {
    let config = &worker.config;
    let auth = config.worker_auth().cloned().unwrap_or_else(|| {
        WorkerAuthCredentials::new(
            "unconfigured-media-worker-token",
            "00000000-0000-4000-8000-000000000000",
            "1",
        )
    });

    let (client, js, cert_policy) = connect_nats_and_jetstream(config).await?;
    ensure_media_streams(&js, config).await?;

    let _text_handle = spawn_nats_text_embed_responder(
        client.clone(),
        &worker,
        Arc::clone(&metrics),
        shutdown.clone(),
    )
    .await?;

    if let Some((readiness, manifest)) = ready_state {
        readiness.mark_ready(manifest);
        info!("NATS text-embed RPC responder subscribed and /readyz marked ready");
    }

    let grant_client =
        HttpControlPlaneGrantClient::new(config.control_plane_url(), auth, Duration::from_secs(10));
    let mut nvr_reader = NvrAnalysisReader::new(
        config.nvr_scheme(),
        config.nvr_read_port(),
        Duration::from_secs(10),
    );
    if let Some(suffix) = config.nvr_host_suffix() {
        nvr_reader = nvr_reader.with_host_suffix(suffix);
    }
    if let (Some(ca), Some(cert), Some(key)) = (
        config.nvr_tls_ca_file(),
        config.nvr_tls_cert_file(),
        config.nvr_tls_key_file(),
    ) {
        nvr_reader = nvr_reader.with_mtls(ca, cert, key);
    }
    if let Some(token_file) = config.nvr_auth_token_file() {
        nvr_reader = nvr_reader.with_auth_token_file(token_file);
    }
    let store = HybridGrantStore::new(
        LongshoreArchiveReader::new(
            config.index_concurrency().clamp(1, 4),
            Duration::from_secs(15),
        ),
        nvr_reader,
    );
    let publisher = JetStreamResultPublisher::new(js.clone(), cert_policy, Duration::from_secs(10));
    let processor = VisualIndexProcessor::with_backend(
        config,
        worker.backend,
        grant_client.clone(),
        store.clone(),
        publisher.clone(),
        Arc::clone(&metrics),
    );

    let _vantage_handle = if config.vantage_vlm_enabled() {
        let vlm_client = HttpVlmClient::from_config(config)?;
        let vantage_processor = VantageVlmProcessor::new(
            config,
            grant_client,
            store,
            publisher,
            vlm_client,
            Arc::clone(&metrics),
        );
        let vantage_live_consumer = ensure_pull_consumer(
            &js,
            config.jobs_stream_name(),
            &format!("{}_live", config.vantage_consumer_name()),
            VANTAGE_VLM_LIVE_SUBJECT,
            config.vantage_vlm_concurrency(),
        )
        .await?;
        let vantage_backfill_consumer = ensure_pull_consumer(
            &js,
            config.jobs_stream_name(),
            &format!("{}_backfill", config.vantage_consumer_name()),
            VANTAGE_VLM_BACKFILL_SUBJECT,
            config.vantage_vlm_concurrency(),
        )
        .await?;
        let mut vantage_shutdown = shutdown.clone();
        info!(
            live_subject = VANTAGE_VLM_LIVE_SUBJECT,
            backfill_subject = VANTAGE_VLM_BACKFILL_SUBJECT,
            vantage_vlm_concurrency = config.vantage_vlm_concurrency(),
            "started isolated JetStream Vantage VLM pull loop"
        );
        Some(tokio::spawn(async move {
            while !*vantage_shutdown.borrow_and_update() {
                let pulled_live =
                    pull_and_spawn_vantage_batch(&vantage_live_consumer, &vantage_processor, 1)
                        .await;
                if pulled_live == 0 {
                    let pulled_backfill = pull_and_spawn_vantage_batch(
                        &vantage_backfill_consumer,
                        &vantage_processor,
                        1,
                    )
                    .await;
                    if pulled_backfill == 0 {
                        tokio::select! {
                            _ = vantage_shutdown.changed() => break,
                            _ = tokio::time::sleep(Duration::from_millis(250)) => {}
                        }
                    }
                }
            }
        }))
    } else {
        None
    };

    let live_consumer = ensure_pull_consumer(
        &js,
        config.jobs_stream_name(),
        &format!("{}_live", config.consumer_name()),
        VISUAL_INDEX_LIVE_SUBJECT,
        config.index_concurrency(),
    )
    .await?;
    let backfill_consumer = ensure_pull_consumer(
        &js,
        config.jobs_stream_name(),
        &format!("{}_backfill", config.consumer_name()),
        VISUAL_INDEX_BACKFILL_SUBJECT,
        config.index_concurrency(),
    )
    .await?;

    info!(
        live_subject = VISUAL_INDEX_LIVE_SUBJECT,
        backfill_subject = VISUAL_INDEX_BACKFILL_SUBJECT,
        index_concurrency = config.index_concurrency(),
        "started JetStream visual-index pull loop"
    );

    while !*shutdown.borrow_and_update() {
        // Poll live newly-sealed blocks first before historical backfill (`design.md` Risks/Trade-offs).
        let pulled_live = pull_and_spawn_batch(&live_consumer, &processor, 1).await;
        if pulled_live == 0 {
            let pulled_backfill = pull_and_spawn_batch(&backfill_consumer, &processor, 1).await;
            if pulled_backfill == 0 {
                tokio::select! {
                    _ = shutdown.changed() => break,
                    _ = tokio::time::sleep(Duration::from_millis(250)) => {}
                }
            }
        }
    }

    Ok(())
}

async fn pull_and_spawn_batch<G, S, P>(
    consumer: &jetstream::consumer::Consumer<pull::Config>,
    processor: &VisualIndexProcessor<G, S, P>,
    max_messages: usize,
) -> usize
where
    G: GrantClient + 'static,
    S: FragmentStore + 'static,
    P: ResultPublisher + 'static,
{
    if processor.index_semaphore().available_permits() == 0 {
        tokio::time::sleep(Duration::from_millis(25)).await;
        return 0;
    }

    let Ok(mut batch) = consumer
        .fetch()
        .max_messages(max_messages)
        .expires(Duration::from_millis(200))
        .messages()
        .await
    else {
        return 0;
    };

    let mut count = 0usize;
    while let Some(Ok(msg)) = batch.next().await {
        count += 1;
        let proc_clone = processor.clone();
        let delivery = Arc::new(JetStreamJobDelivery::new(msg));
        tokio::spawn(async move {
            if let Err(err) = proc_clone.process_delivery(delivery).await {
                warn!(error = %err, "visual index job failed");
            }
        });
    }
    count
}

async fn pull_and_spawn_vantage_batch<G, S, P, V>(
    consumer: &jetstream::consumer::Consumer<pull::Config>,
    processor: &VantageVlmProcessor<G, S, P, V>,
    max_messages: usize,
) -> usize
where
    G: GrantClient + 'static,
    S: FragmentStore + 'static,
    P: ResultPublisher + 'static,
    V: crate::vantage_vlm::VlmClient + 'static,
{
    if processor.semaphore().available_permits() == 0 {
        tokio::time::sleep(Duration::from_millis(25)).await;
        return 0;
    }

    let Ok(mut batch) = consumer
        .fetch()
        .max_messages(max_messages)
        .expires(Duration::from_millis(200))
        .messages()
        .await
    else {
        return 0;
    };

    let mut count = 0usize;
    while let Some(Ok(msg)) = batch.next().await {
        count += 1;
        let proc_clone = processor.clone();
        let delivery = Arc::new(JetStreamJobDelivery::new(msg));
        tokio::spawn(async move {
            if let Err(err) = proc_clone.process_delivery(delivery).await {
                warn!(error = %err, "vantage VLM job failed");
            }
        });
    }
    count
}

async fn connect_nats_and_jetstream(
    config: &WorkerConfig,
) -> Result<
    (
        Client,
        jetstream::Context,
        Option<Arc<serviceradar_cert_policy::nats::Guard>>,
    ),
    MediaWorkerError,
> {
    ensure_rustls_provider();
    let mut options = ConnectOptions::new().custom_inbox_prefix(config.nats_inbox_prefix());

    if let Some(creds_file) = config.nats_creds_file() {
        options = options.credentials_file(creds_file).await.map_err(|err| {
            MediaWorkerError::nats_error(format!(
                "failed loading NATS creds file {}: {err}",
                creds_file.display()
            ))
        })?;
    }

    let has_tls = config.nats_tls_ca_file().is_some()
        || (config.nats_tls_cert_file().is_some() && config.nats_tls_key_file().is_some());
    if has_tls {
        options = options.require_tls(true);
    }
    if let Some(ca) = config.nats_tls_ca_file() {
        options = options.add_root_certificates(ca.to_path_buf());
    }
    if let (Some(cert), Some(key)) = (config.nats_tls_cert_file(), config.nats_tls_key_file()) {
        options = options.add_client_certificate(cert.to_path_buf(), key.to_path_buf());
    }

    let (client, guard) = serviceradar_cert_policy::nats::connect(
        options,
        config.nats_url(),
        config.nats_cert_policy_file().map(Path::new),
        None,
        config.nats_tls_ca_file().map(Path::new),
        config.nats_tls_cert_file().map(Path::new),
        config.nats_tls_key_file().map(Path::new),
    )
    .await
    .map_err(|err| MediaWorkerError::nats_error(format!("NATS connect failed: {err}")))?;

    let js = match config.nats_domain() {
        Some(domain) => jetstream::with_domain(client.clone(), domain),
        None => jetstream::new(client.clone()),
    };

    Ok((client, js, guard.map(Arc::new)))
}

async fn ensure_media_streams(
    js: &jetstream::Context,
    config: &WorkerConfig,
) -> Result<(), MediaWorkerError> {
    let jobs_cfg = jetstream::stream::Config {
        name: config.jobs_stream_name().to_string(),
        subjects: vec![
            VISUAL_INDEX_LIVE_SUBJECT.to_string(),
            VISUAL_INDEX_BACKFILL_SUBJECT.to_string(),
            VANTAGE_VLM_LIVE_SUBJECT.to_string(),
            VANTAGE_VLM_BACKFILL_SUBJECT.to_string(),
        ],
        retention: RetentionPolicy::Limits,
        storage: StorageType::File,
        max_age: Duration::from_secs(72 * 3600),
        max_bytes: 512 * 1024 * 1024,
        ..Default::default()
    };
    if let Err(err) = js.get_or_create_stream(jobs_cfg).await {
        warn!(error = %err, "get_or_create_stream for jobs stream returned warning; continuing if pre-provisioned");
    }

    let results_cfg = jetstream::stream::Config {
        name: config.results_stream_name().to_string(),
        subjects: vec![
            VISUAL_INDEX_RESULTS_SUBJECT.to_string(),
            VANTAGE_RESULTS_SUBJECT.to_string(),
        ],
        retention: RetentionPolicy::Limits,
        storage: StorageType::File,
        max_age: Duration::from_secs(72 * 3600),
        max_bytes: 2 * 1024 * 1024 * 1024,
        ..Default::default()
    };
    if let Err(err) = js.get_or_create_stream(results_cfg).await {
        warn!(error = %err, "get_or_create_stream for results stream returned warning; continuing if pre-provisioned");
    }

    Ok(())
}

async fn ensure_pull_consumer(
    js: &jetstream::Context,
    stream_name: &str,
    durable_name: &str,
    filter_subject: &str,
    concurrency: usize,
) -> Result<jetstream::consumer::Consumer<pull::Config>, MediaWorkerError> {
    let stream = js.get_stream(stream_name).await.map_err(|err| {
        MediaWorkerError::nats_error(format!(
            "JetStream stream '{stream_name}' unavailable: {err}"
        ))
    })?;

    let cfg = pull::Config {
        durable_name: Some(durable_name.to_string()),
        filter_subject: filter_subject.to_string(),
        ack_policy: AckPolicy::Explicit,
        ack_wait: Duration::from_secs(60),
        max_deliver: 5,
        max_ack_pending: (concurrency.max(1) * 4) as i64,
        ..Default::default()
    };

    stream
        .get_or_create_consumer(durable_name, cfg)
        .await
        .map_err(|err| {
            MediaWorkerError::nats_error(format!(
                "failed creating JetStream pull consumer '{durable_name}' on '{stream_name}': {err}"
            ))
        })
}

fn ensure_rustls_provider() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[cfg(test)]
impl JobOutcome {
    pub fn completed_envelope(&self) -> Option<&VisualIndexResultEnvelope> {
        match self {
            Self::Completed(env) => Some(env),
            Self::Gone => None,
        }
    }
}

#[cfg(test)]
pub(crate) fn log_worker_error(err: &MediaWorkerError) {
    tracing::error!(error = %err, "media worker error");
}
