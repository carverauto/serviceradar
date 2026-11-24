//! Per-clip multi-object tracking delegated to [`serviceradar_media_core::MultiObjectTracker`].
//!
//! Each clip / segment instantiates a fresh [`ClipTracker`] so `serviceradar-media-worker`
//! remains completely stateless across clips while sharing the single canonical `trackforge`
//! implementation in `serviceradar-media-core`.

use crate::vision::{DetectedSubject, ObjectClass};
use core::fmt::{self, Formatter};
use serde::{Deserialize, Serialize};
use serviceradar_media_core::{
    Detection, MultiObjectTracker, ObjectCategory, TrackerConfig, keyframe_quality_score,
};

pub use serviceradar_media_core::TrackerMode;

/// Default confidence threshold for high-confidence track association (matches Stage 1 floor).
const TRACK_CONFIDENCE_THRESH: f32 = 0.35;
/// Default maximum missed frames before a lost track is evicted.
const TRACK_BUFFER_FRAMES: u32 = 30;

/// Aggregated per-track metadata computed across all keyframes of a clip.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackSummary {
    track_id: u64,
    object_class: ObjectClass,
    first_seen_offset_ms: u64,
    last_seen_offset_ms: u64,
    dwell_ms: u64,
    frame_count: u32,
    peak_confidence: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    best_keyframe_offset_ms: Option<u64>,
}

impl TrackSummary {
    pub fn track_id(&self) -> u64 {
        self.track_id
    }

    pub fn object_class(&self) -> ObjectClass {
        self.object_class
    }

    pub(crate) fn set_object_class(&mut self, object_class: ObjectClass) {
        self.object_class = object_class;
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

    pub fn best_keyframe_offset_ms(&self) -> Option<u64> {
        self.best_keyframe_offset_ms
    }
}

/// Computes the crop quality score used for best-crop deduplication via
/// [`serviceradar_media_core::keyframe_quality_score`]: `confidence * normalized_box_area`.
pub fn crop_quality_score(confidence: f32, bbox_norm: [f32; 4]) -> f32 {
    keyframe_quality_score(confidence, bbox_norm, 1.0)
}

pub(crate) fn object_class_to_category(cls: ObjectClass) -> ObjectCategory {
    match cls {
        ObjectClass::Person => ObjectCategory::Person,
        ObjectClass::Vehicle => ObjectCategory::Vehicle,
        ObjectClass::Bicycle => ObjectCategory::Bicycle,
        ObjectClass::Animal => ObjectCategory::Animal,
        ObjectClass::Package => ObjectCategory::Package,
    }
}

pub(crate) fn category_to_object_class(cat: ObjectCategory) -> ObjectClass {
    match cat {
        ObjectCategory::Person => ObjectClass::Person,
        ObjectCategory::Vehicle => ObjectClass::Vehicle,
        ObjectCategory::Bicycle => ObjectClass::Bicycle,
        ObjectCategory::Animal => ObjectClass::Animal,
        ObjectCategory::Package | ObjectCategory::Motion => ObjectClass::Package,
    }
}

/// Stateless-across-clips per-clip multi-object tracker backed by
/// [`serviceradar_media_core::MultiObjectTracker`].
pub struct ClipTracker {
    inner: MultiObjectTracker,
}

impl fmt::Debug for ClipTracker {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClipTracker")
            .field("inner", &self.inner)
            .finish()
    }
}

impl ClipTracker {
    /// Creates a fresh tracker instance for one clip or live camera stream.
    pub fn new(mode: TrackerMode) -> Self {
        let config = TrackerConfig {
            mode,
            min_hits_to_activate: 1,
            max_lost_frames: TRACK_BUFFER_FRAMES,
            max_lost_ms: 0,
            max_tracks: 128,
            max_closed_tracks: 256,
            confidence_threshold: TRACK_CONFIDENCE_THRESH,
        };
        Self {
            inner: MultiObjectTracker::new("clip", config),
        }
    }

    pub fn mode(&self) -> TrackerMode {
        self.inner.config().mode
    }

    pub fn inner(&self) -> &MultiObjectTracker {
        &self.inner
    }

    /// Feeds one keyframe's Stage 1 detections (and optional L2-normalized crop embeddings
    /// when using an appearance-assisted mode) into `serviceradar-media-core`'s
    /// [`MultiObjectTracker`], returning a vector of assigned `Option<u64>` `track_id`s
    /// parallel to `detections`.
    pub fn update_frame(
        &mut self,
        frame_width: u32,
        frame_height: u32,
        offset_ms: u64,
        detections: &[DetectedSubject],
        embeddings: Option<&[Vec<f32>]>,
    ) -> Vec<Option<u64>> {
        let mc_dets: Vec<Detection> = detections
            .iter()
            .map(|det| {
                let category = object_class_to_category(det.object_class());
                Detection::new(
                    category.class_id(),
                    category,
                    det.confidence(),
                    det.bbox_norm(),
                )
            })
            .collect();

        self.inner
            .update(
                (frame_width, frame_height),
                offset_ms,
                &mc_dets,
                None,
                embeddings,
                None,
            )
            .assigned_track_ids
    }

    /// Returns deterministic per-track summaries ordered by `track_id`.
    pub fn summaries(&self) -> Vec<TrackSummary> {
        self.inner
            .all_summaries()
            .into_iter()
            .map(|s| TrackSummary {
                track_id: s.track_id,
                object_class: category_to_object_class(s.category),
                first_seen_offset_ms: s.first_seen_ms,
                last_seen_offset_ms: s.last_seen_ms,
                dwell_ms: s.dwell_ms,
                frame_count: s.frame_count,
                peak_confidence: s.peak_confidence,
                best_keyframe_offset_ms: Some(s.best_keyframe.timestamp_ms),
            })
            .collect()
    }
}
