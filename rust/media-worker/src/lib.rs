//! `serviceradar-media-worker` — Standalone stateless GPU media worker for NVR
//! semantic visual clip search (`openspec/changes/add-camera-semantic-clip-search`).

mod capability;
mod cmaf;
mod config;
mod credentials;
mod errors;
mod grants;
mod http_server;
mod metrics;
mod ort_loader;
mod range_reader;
mod vision;
mod worker;

#[cfg(test)]
mod tests;

pub use capability::{
    CapabilityManifest, GpuEnvironmentObservation, GpuEnvironmentProbe, SystemGpuEnvironmentProbe,
    verify_startup_capabilities,
};
pub use cmaf::{
    ParsedInitSegment, ParsedMediaFragment, SyntheticCmafBlock, SyntheticColor,
    SyntheticFragmentSpec, SyntheticObjectSpec, VideoCodec, decode_idr_keyframe,
    generate_synthetic_cmaf_block, parse_init_segment, parse_media_fragment,
    render_synthetic_pattern_frame,
};
pub use config::{CliArgs, ExecutionProvider, GpuSharingMode, ModelPinConfig, WorkerConfig};
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
pub use vision::{
    DetectedSubject, GeneratedEmbedding, KeyframeAnalysis, ObjectClass, RgbFrame, VisionPipeline,
    classify_dominant_colors, cosine_similarity, embed_query_text,
};
pub use worker::{
    DetectionPayload, EmbeddingPayload, FrameResultPayload, JetStreamJobDelivery,
    JetStreamResultPublisher, JobDelivery, JobOutcome, ResultPublisher, TextEmbedRpcRequest,
    TextEmbedRpcResponse, TextEmbedService, VISUAL_INDEX_BACKFILL_SUBJECT,
    VISUAL_INDEX_LIVE_SUBJECT, VISUAL_INDEX_RESULTS_SUBJECT, VISUAL_TEXT_EMBED_QUEUE_GROUP,
    VISUAL_TEXT_EMBED_RPC_PREFIX, VisualIndexJobEnvelope, VisualIndexProcessor,
    VisualIndexResultEnvelope, run_nats_worker_loops, spawn_nats_text_embed_responder,
    text_embed_rpc_subject,
};
