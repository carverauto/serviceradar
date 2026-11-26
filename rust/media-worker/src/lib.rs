//! `serviceradar-media-worker` — Standalone stateless GPU media worker for NVR
//! semantic visual clip search (`openspec/changes/add-camera-semantic-clip-search`).

mod backend;
mod candle_backend;
mod capability;
mod cmaf;
mod config;
mod credentials;
mod errors;
mod grants;
mod h264;
mod http_server;
mod keyframe_decoder;
mod metrics;
mod ort_loader;
mod range_reader;
mod tokenizer;
mod tracking;
mod vantage_vlm;
mod vision;
mod worker;
mod yolox;

#[cfg(test)]
mod candle_tests;
#[cfg(test)]
mod keyframe_decoder_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tracking_tests;

pub use backend::{
    DeterministicStubBackend, InferenceBackend, InferenceBackendInfo, InferenceBackendKind,
    InferenceDevicePreference, InferencePrecision, RawDetection, build_inference_backend,
};
pub use candle_backend::{CandleBackend, CandleBackendOptions, resolve_candle_device};
pub use capability::{
    CapabilityManifest, GpuEnvironmentObservation, GpuEnvironmentProbe, SystemGpuEnvironmentProbe,
    verify_startup_capabilities, verify_startup_capabilities_with_backend,
};
pub use cmaf::{
    ParsedInitSegment, ParsedMediaFragment, SyntheticCmafBlock, SyntheticColor,
    SyntheticFragmentSpec, SyntheticObjectSpec, VideoCodec, generate_synthetic_cmaf_block,
    parse_init_segment, parse_media_fragment, render_synthetic_pattern_frame,
};
pub use config::{
    CliArgs, DEFAULT_VANTAGE_CONSUMER_NAME, DEFAULT_VANTAGE_VLM_MODEL, DEFAULT_VANTAGE_VLM_URL,
    DEFAULT_VANTAGE_WORKER_ID, ExecutionProvider, GpuSharingMode, ModelPinConfig,
    RedactedVlmApiKey, WorkerConfig, normalize_vlm_url,
};
pub use credentials::{EphemeralS3Credentials, RedactedPresignedUrl, WorkerAuthCredentials};
pub use errors::{
    CapabilityError, CapabilityErrorKind, IntegrityError, IntegrityErrorKind, MediaWorkerError,
    MediaWorkerErrorKind,
};
pub use grants::{
    ArchiveGrantTarget, ArchiveMediaObjectPlan, ArchivePlanSpec, BackingSource, BrokerGrantScope,
    CoalescedRange, FragmentSlicePlan, GrantClient, GrantResolution, HEADER_CONTROL_PLANE_AUTH,
    HEADER_DEPLOYMENT_REF, HEADER_MEDIA_WORKER_GENERATION, HttpControlPlaneGrantClient,
    InitSlicePlan, LocalGrantTarget, LocalPlanSpec, RangeSlice, ReadGrantPlan, ReadGrantRequest,
};
pub use http_server::{ReadinessState, build_http_router, serve_http_probes};
pub use keyframe_decoder::{
    DefaultKeyframeDecoder, KeyframeDecodeError, KeyframeDecodeErrorKind, KeyframeDecoder,
    MAX_KEYFRAME_ACCESS_UNIT_BYTES, MAX_PARAMETER_SET_BYTES,
};
pub use metrics::{
    InflightGuard, MEDIA_WORKER_TELEMETRY_SUBJECT, TelemetrySnapshot, WorkerMetrics,
};
pub use ort_loader::{OrtRuntimeProbeResult, discover_default_ort_dylib, probe_ort_dylib};
pub use range_reader::{
    FragmentStore, HybridGrantStore, LongshoreArchiveReader, MAX_COALESCE_GAP_BYTES,
    MAX_COALESCED_RANGE_BYTES, MAX_INIT_SEGMENT_BYTES, MAX_LONGSHORE_REGISTERED_POOL_BYTES,
    NvrAnalysisReader, VerifiedFragmentBytes, VerifiedKeyframeBlock, coalesce_fragment_ranges,
    extract_and_verify_slices, longshore_registered_pool_bytes, verify_sha256_hex,
};
pub use serviceradar_media_core as media_core;
pub use serviceradar_media_core::{
    ColorName, CompressedFrameGate, CompressedFrameGateConfig, CropConfig, CropOutcome, CropPolicy,
    CropSkipReason, Detection, DetectionEvent, DetectionEventKind, EncodedCrop, EncodedThumbnail,
    GateAdmitReason, GateDecision, InputMode, LetterboxTransform, LiveFramePayloadFormat,
    LumaPlane, LumaPlaneView, MAX_VLM_MAX_TOKENS, MediaCoreError, MediaPipeline,
    MediaPipelineConfig, MotionGridMap, MultiObjectTracker, ObjectCategory, ObjectDetector,
    PipelineFrameOutput, PixelMotionGate, PixelMotionGateConfig, PixelMotionMetrics,
    RgbCropOutcome, RoiGridMask, RoiMask, RoiPolygon, SampledTarget, SourceMode, SyntheticDetector,
    ThumbnailConfig, TimeBasis, TrackState, TrackerConfig, TwoTierFrameGate, VantageFrameContext,
    VantageJobEnvelope, VantageLiveFrameEnvelope, VantageObservationInput, VantageResultEnvelope,
    VantageUpstreamDetection, VantageWorkerHeartbeat, VisualAttributes, VlmJobConfig, WorkerHealth,
    WorkerKind, YoloxConfig, YoloxPostProcessor, crop_detection_in_rois_jpeg, crop_detection_jpeg,
    crop_detection_rgb, crop_roi_polygon_jpeg, crop_roi_polygon_rgb, crop_roi_polygons_jpeg,
    encode_jpeg_thumbnail, expand_bbox_padded, extract_visual_attributes,
};
pub use tokenizer::PureRustTokenizer;
pub use tracking::{ClipTracker, TrackSummary, TrackerMode, crop_quality_score};
pub use vantage_vlm::{
    HttpVlmClient, ParsedVlmReading, VantageJobOutcome, VantageVlmProcessor, VlmCallError,
    VlmChatRequest, VlmClient, VlmParseFailure, parse_vlm_json_response,
};
pub use vision::{
    BackendObjectDetector, ClipAnalysis, ClipKeyframe, DetectedSubject, GeneratedEmbedding,
    KeyframeAnalysis, MAX_ENVELOPE_THUMBNAIL_B64_BYTES, MAX_THUMBNAIL_JPEG_BYTES, ObjectClass,
    RgbFrame, VisionPipeline, classify_dominant_colors, cosine_similarity, embed_query_text,
};
pub use worker::{
    AdmittedWorker, DetectionPayload, EmbeddingPayload, FrameResultPayload, JetStreamJobDelivery,
    JetStreamResultPublisher, JobDelivery, JobOutcome, MAX_RESULT_ENVELOPE_JSON_BYTES,
    ResultPublisher, TextEmbedRpcRequest, TextEmbedRpcResponse, TrackSummaryPayload,
    UndecodableKeyframePayload, VANTAGE_RESULTS_SUBJECT, VANTAGE_VLM_BACKFILL_SUBJECT,
    VANTAGE_VLM_LIVE_SUBJECT, VISUAL_INDEX_BACKFILL_SUBJECT, VISUAL_INDEX_LIVE_SUBJECT,
    VISUAL_INDEX_RESULTS_SUBJECT, VISUAL_TEXT_EMBED_QUEUE_GROUP, VISUAL_TEXT_EMBED_RPC_PREFIX,
    VisualIndexJobEnvelope, VisualIndexProcessor, VisualIndexResultEnvelope, load_and_admit_worker,
    run_admitted_nats_worker, run_admitted_nats_worker_with_readiness, run_nats_worker_loops,
    run_nats_worker_loops_with_backend, text_embed_rpc_subject,
};
pub use yolox::{
    YoloxDetector, YoloxDetectorConfig, coco_class_to_object_class, coco_name_to_object_class,
};
