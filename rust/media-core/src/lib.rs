//! `serviceradar-media-core` — Pure-Rust video analysis primitives shared across
//! `serviceradar-media-worker` and edge/live tracking services:
//!
//! - [`frame_gate`]: Two-tier frame-change and motion gate (Tier 0 zero-decode compressed
//!   payload size/hash gate + Tier 1 spatial-grid luma/RGB SAD/MAD motion gate with ROI mask).
//! - [`detector`]: Apache-2.0 YOLOX object detector interface, anchor-free grid decoder,
//!   letterbox geometry, class-aware NMS, and deterministic synthetic detector.
//! - [`attributes`]: HSV sub-crop (upper-body / lower-body / full-object) color and visual
//!   attribute extraction.
//! - [`tracker`]: `trackforge`-powered multi-object tracker with explicit track lifecycle
//!   (`New` -> `Active` -> `Lost` -> `Closed`), best-keyframe selection, and `DetectionEvent`s.
//! - [`thumbnail`]: Bounded pure-Rust Baseline JPEG keyframe thumbnail encoder with SHA-256.
//! - [`pipeline`]: Cohesive end-to-end stage pipeline combining all stages.

#![forbid(unsafe_code)]

pub mod attributes;
pub mod crop;
pub mod detector;
pub mod error;
pub mod frame;
pub mod frame_gate;
pub mod pipeline;
pub mod thumbnail;
pub mod tracker;
pub mod vantage_protocol;

pub use attributes::{
    ColorName, VisualAttributes, classify_crop_colors, classify_hsv_color,
    extract_visual_attributes, rgb_to_hsv,
};
pub use crop::{
    CropConfig, CropOutcome, CropSkipReason, DEFAULT_CROP_PADDING_RATIO, DEFAULT_MAX_CROP_BYTES,
    DEFAULT_MAX_CROP_DIMENSION, DEFAULT_MIN_BBOX_WIDTH_PX, EncodedCrop, HARD_MAX_CROP_BYTES,
    HARD_MAX_CROP_DIMENSION, RgbCropOutcome, RoiPolygon, STORED_PREVIEW_MAX_BYTES,
    crop_detection_in_rois_jpeg, crop_detection_jpeg, crop_detection_rgb, crop_roi_polygon_jpeg,
    crop_roi_polygon_rgb, crop_roi_polygons_jpeg, expand_bbox_padded,
};
pub use detector::{
    Detection, LetterboxTransform, ObjectCategory, ObjectDetector, SyntheticDetector, YoloxConfig,
    YoloxPostProcessor, apply_class_aware_nms, bbox_iou, clamp_unit_bbox, coco_class_to_category,
    coco_name_to_category,
};
pub use error::{MediaCoreError, MediaCoreErrorKind};
pub use frame::{LumaPlane, LumaPlaneView, MAX_FRAME_DIMENSION, RgbFrame};
pub use frame_gate::{
    CompressedFrameGate, CompressedFrameGateConfig, GateAdmitReason, GateDecision, MotionGridMap,
    PixelMotionGate, PixelMotionGateConfig, PixelMotionMetrics, RoiGridMask, RoiMask,
    TwoTierFrameGate,
};
pub use pipeline::{MediaPipeline, MediaPipelineConfig, PipelineFrameOutput};
pub use thumbnail::{EncodedThumbnail, ThumbnailConfig, downscale_rgb_fit, encode_jpeg_thumbnail};
pub use tracker::{
    BestKeyframeSnapshot, DetectionEvent, DetectionEventKind, MultiObjectTracker, TrackState,
    TrackSummary, TrackerConfig, TrackerMode, TrackerStepOutput, keyframe_quality_score,
};
pub use vantage_protocol::{
    CropPolicy, DEFAULT_VANTAGE_JOB_BUDGET_MS, InputMode, LiveFramePayloadFormat,
    MAX_STORED_CROP_JPEG_BYTES, MAX_VANTAGE_JOB_ENVELOPE_BYTES, MAX_VANTAGE_RESULT_ENVELOPE_BYTES,
    MAX_VLM_MAX_TOKENS, SampledTarget, SourceMode, TimeBasis, VANTAGE_FRAME_SCHEMA_VERSION,
    VANTAGE_HEARTBEAT_SCHEMA_VERSION, VANTAGE_HEARTBEAT_SUBJECT, VANTAGE_JOB_SCHEMA_VERSION,
    VANTAGE_RESULT_SCHEMA_VERSION, VANTAGE_RESULTS_SUBJECT, VANTAGE_VLM_BACKFILL_SUBJECT,
    VANTAGE_VLM_JOBS_SUBJECT, VANTAGE_WORKER_PROTOCOL_VERSION, VantageFrameContext,
    VantageJobEnvelope, VantageLiveFrameEnvelope, VantageObservationInput, VantageResultEnvelope,
    VantageUpstreamDetection, VantageWorkerHeartbeat, VlmJobConfig, WorkerHealth, WorkerKind,
    capability_slug, job_subject_for_capability, live_subject_for_capability,
};
