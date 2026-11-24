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
pub mod detector;
pub mod error;
pub mod frame;
pub mod frame_gate;
pub mod pipeline;
pub mod thumbnail;
pub mod tracker;

pub use attributes::{
    ColorName, VisualAttributes, classify_crop_colors, classify_hsv_color,
    extract_visual_attributes, rgb_to_hsv,
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
