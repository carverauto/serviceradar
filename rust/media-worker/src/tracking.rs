//! Per-clip multi-object tracking powered by `trackforge` (`ByteTrack`, `BoT-SORT`, `Deep OC-SORT`).
//!
//! Each clip / segment instantiates a fresh [`ClipTracker`] so `serviceradar-media-worker`
//! remains completely stateless across clips while producing persistent `track_id`s and
//! per-track dwell/summary metadata within a clip (and remaining directly reusable for
//! future per-camera live streams).

use crate::errors::CapabilityError;
use crate::vision::{DetectedSubject, ObjectClass};
use core::fmt::{self, Display, Formatter};
use core::str::FromStr;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use trackforge::trackers::botsort::BotSort;
use trackforge::trackers::byte_track::ByteTrack;
use trackforge::trackers::deep_ocsort::DeepOcSortTracker;
use trackforge::trackers::deepsort::{Metric, NearestNeighborDistanceMetric};

/// Default confidence threshold for high-confidence track association (matches Stage 1 floor).
const TRACK_CONFIDENCE_THRESH: f32 = 0.35;
/// Default maximum missed frames before a lost track is evicted.
const TRACK_BUFFER_FRAMES: usize = 30;
/// Default IoU distance ceiling (`1 - IoU`) for keyframe-rate motion matching.
const TRACK_MATCH_IOU_DIST: f32 = 0.85;
/// Default cosine distance ceiling for appearance-assisted Re-ID matching (`cos_sim >= 0.65`).
const TRACK_APPEARANCE_COSINE_DIST: f32 = 0.35;
/// Default spatial proximity gate (`1 - IoU`) for BoT-SORT appearance fusion.
const BOTSORT_PROXIMITY_IOU_DIST: f32 = 0.90;
/// Default minimum IoU for Deep OC-SORT motion+appearance association.
const DEEP_OCSORT_MIN_IOU: f32 = 0.15;
/// Default observation window for Deep OC-SORT velocity estimation.
const DEEP_OCSORT_DELTA_T: usize = 3;
/// Default OCM direction-consistency inertia weight for Deep OC-SORT.
const DEEP_OCSORT_INERTIA: f32 = 0.2;
/// Default appearance blend weight for Deep OC-SORT.
const DEEP_OCSORT_APPEARANCE_WEIGHT: f32 = 0.5;
/// Default per-track appearance gallery budget for Deep OC-SORT.
const DEEP_OCSORT_NN_BUDGET: usize = 32;

/// Configurable multi-object tracker algorithm (`MEDIA_WORKER_TRACKER`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub enum TrackerMode {
    /// Motion-only two-stage IoU association (`trackforge::trackers::byte_track::ByteTrack`).
    #[default]
    #[serde(rename = "bytetrack")]
    ByteTrack,
    /// Motion + appearance-fused Re-ID association (`trackforge::trackers::botsort::BotSort`).
    #[serde(rename = "botsort")]
    BotSort,
    /// Observation-centric motion + appearance gallery (`trackforge::trackers::deep_ocsort::DeepOcSortTracker`).
    #[serde(rename = "deep_ocsort")]
    DeepOcSort,
    /// Tracking disabled; preserves legacy untracked per-frame behavior.
    #[serde(rename = "off")]
    Off,
}

impl TrackerMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ByteTrack => "bytetrack",
            Self::BotSort => "botsort",
            Self::DeepOcSort => "deep_ocsort",
            Self::Off => "off",
        }
    }

    pub fn is_enabled(self) -> bool {
        !matches!(self, Self::Off)
    }

    pub fn uses_appearance(self) -> bool {
        matches!(self, Self::BotSort | Self::DeepOcSort)
    }
}

impl Display for TrackerMode {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TrackerMode {
    type Err = CapabilityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "bytetrack" | "byte_track" => Ok(Self::ByteTrack),
            "botsort" | "bot_sort" => Ok(Self::BotSort),
            "deep_ocsort" | "deepocsort" => Ok(Self::DeepOcSort),
            "off" | "none" | "disabled" => Ok(Self::Off),
            other => Err(CapabilityError::invalid_configuration(format!(
                "unsupported tracker '{other}'; expected 'bytetrack', 'botsort', 'deep_ocsort', or 'off'"
            ))),
        }
    }
}

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
}

impl TrackSummary {
    pub fn track_id(&self) -> u64 {
        self.track_id
    }

    pub fn object_class(&self) -> ObjectClass {
        self.object_class
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

/// Computes the crop quality score used for best-crop deduplication:
/// `confidence * normalized_box_area`.
pub fn crop_quality_score(confidence: f32, bbox_norm: [f32; 4]) -> f32 {
    let width = (bbox_norm[2] - bbox_norm[0]).max(0.0);
    let height = (bbox_norm[3] - bbox_norm[1]).max(0.0);
    confidence.max(0.0) * (width * height)
}

#[derive(Debug, Clone)]
struct TrackAccum {
    object_class: ObjectClass,
    first_seen_offset_ms: u64,
    last_seen_offset_ms: u64,
    frame_count: u32,
    peak_confidence: f32,
}

enum TrackerEngine {
    Off,
    ByteTrack(ByteTrack),
    BotSort(BotSort),
    DeepOcSort(DeepOcSortTracker),
}

/// Stateless-across-clips per-clip multi-object tracker wrapping `trackforge`.
pub struct ClipTracker {
    mode: TrackerMode,
    engine: TrackerEngine,
    tracks: BTreeMap<u64, TrackAccum>,
}

impl core::fmt::Debug for ClipTracker {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClipTracker")
            .field("mode", &self.mode)
            .field("tracked_ids", &self.tracks.len())
            .finish()
    }
}

impl ClipTracker {
    /// Creates a fresh tracker instance for one clip or live camera stream.
    pub fn new(mode: TrackerMode) -> Self {
        let engine = match mode {
            TrackerMode::Off => TrackerEngine::Off,
            TrackerMode::ByteTrack => TrackerEngine::ByteTrack(ByteTrack::new(
                TRACK_CONFIDENCE_THRESH,
                TRACK_BUFFER_FRAMES,
                TRACK_MATCH_IOU_DIST,
                TRACK_CONFIDENCE_THRESH,
            )),
            TrackerMode::BotSort => TrackerEngine::BotSort(BotSort::new(
                TRACK_CONFIDENCE_THRESH,
                TRACK_BUFFER_FRAMES,
                TRACK_MATCH_IOU_DIST,
                TRACK_CONFIDENCE_THRESH,
                BOTSORT_PROXIMITY_IOU_DIST,
                TRACK_APPEARANCE_COSINE_DIST,
            )),
            TrackerMode::DeepOcSort => {
                let metric = NearestNeighborDistanceMetric::new(
                    Metric::Cosine,
                    TRACK_APPEARANCE_COSINE_DIST,
                    Some(DEEP_OCSORT_NN_BUDGET),
                );
                TrackerEngine::DeepOcSort(DeepOcSortTracker::new(
                    TRACK_BUFFER_FRAMES,
                    1,
                    DEEP_OCSORT_MIN_IOU,
                    DEEP_OCSORT_DELTA_T,
                    DEEP_OCSORT_INERTIA,
                    DEEP_OCSORT_APPEARANCE_WEIGHT,
                    TRACK_APPEARANCE_COSINE_DIST,
                    metric,
                ))
            }
        };

        Self {
            mode,
            engine,
            tracks: BTreeMap::new(),
        }
    }

    pub fn mode(&self) -> TrackerMode {
        self.mode
    }

    /// Feeds one keyframe's Stage 1 detections (and optional L2-normalized crop embeddings
    /// when using an appearance-assisted mode) into `trackforge`, returning a vector of
    /// assigned `Option<u64>` `track_id`s parallel to `detections`.
    pub fn update_frame(
        &mut self,
        frame_width: u32,
        frame_height: u32,
        offset_ms: u64,
        detections: &[DetectedSubject],
        embeddings: Option<&[Vec<f32>]>,
    ) -> Vec<Option<u64>> {
        let mut assigned = vec![None; detections.len()];
        if matches!(self.engine, TrackerEngine::Off) {
            return assigned;
        }

        let fw = frame_width.max(1) as f32;
        let fh = frame_height.max(1) as f32;
        let raw_dets: Vec<([f32; 4], f32, i64)> = detections
            .iter()
            .map(|det| {
                let [x1, y1, x2, y2] = det.bbox_norm();
                let tlwh = [
                    x1 * fw,
                    y1 * fh,
                    (x2 - x1).max(1e-4) * fw,
                    (y2 - y1).max(1e-4) * fh,
                ];
                (tlwh, det.confidence(), det.object_class().class_id())
            })
            .collect();

        let emb_slice = embeddings.unwrap_or(&[]);

        match &mut self.engine {
            TrackerEngine::Off => {}
            TrackerEngine::ByteTrack(tracker) => {
                let active = tracker.update(raw_dets.clone());
                assign_track_ids(
                    &raw_dets,
                    active.iter().map(|t| (t.det_ind, t.tlwh, t.track_id)),
                    &mut assigned,
                );
            }
            TrackerEngine::BotSort(tracker) => {
                let active = tracker.update(raw_dets.clone(), emb_slice);
                assign_track_ids(
                    &raw_dets,
                    active.iter().map(|t| (t.det_ind, t.tlwh, t.track_id)),
                    &mut assigned,
                );
            }
            TrackerEngine::DeepOcSort(tracker) => {
                let active = tracker.update(&raw_dets, emb_slice);
                assign_track_ids(
                    &raw_dets,
                    active.iter().map(|t| (t.det_ind, t.tlwh, t.track_id)),
                    &mut assigned,
                );
            }
        }

        for (det, track_id) in detections.iter().zip(assigned.iter()) {
            if let Some(tid) = *track_id {
                self.record_observation(tid, det.object_class(), det.confidence(), offset_ms);
            }
        }

        assigned
    }

    /// Returns deterministic per-track summaries ordered by `track_id`.
    pub fn summaries(&self) -> Vec<TrackSummary> {
        self.tracks
            .iter()
            .map(|(&track_id, acc)| TrackSummary {
                track_id,
                object_class: acc.object_class,
                first_seen_offset_ms: acc.first_seen_offset_ms,
                last_seen_offset_ms: acc.last_seen_offset_ms,
                dwell_ms: acc
                    .last_seen_offset_ms
                    .saturating_sub(acc.first_seen_offset_ms),
                frame_count: acc.frame_count,
                peak_confidence: acc.peak_confidence,
            })
            .collect()
    }

    fn record_observation(
        &mut self,
        track_id: u64,
        object_class: ObjectClass,
        confidence: f32,
        offset_ms: u64,
    ) {
        self.tracks
            .entry(track_id)
            .and_modify(|acc| {
                acc.first_seen_offset_ms = acc.first_seen_offset_ms.min(offset_ms);
                acc.last_seen_offset_ms = acc.last_seen_offset_ms.max(offset_ms);
                acc.frame_count = acc.frame_count.saturating_add(1);
                if confidence > acc.peak_confidence {
                    acc.peak_confidence = confidence;
                    acc.object_class = object_class;
                }
            })
            .or_insert(TrackAccum {
                object_class,
                first_seen_offset_ms: offset_ms,
                last_seen_offset_ms: offset_ms,
                frame_count: 1,
                peak_confidence: confidence,
            });
    }
}

fn assign_track_ids(
    raw_dets: &[([f32; 4], f32, i64)],
    tracks: impl Iterator<Item = (Option<usize>, [f32; 4], u64)>,
    assigned: &mut [Option<u64>],
) {
    let mut fallback: Vec<([f32; 4], u64)> = Vec::new();
    for (det_ind, tlwh, track_id) in tracks {
        if let Some(idx) = det_ind
            && idx < assigned.len()
            && assigned[idx].is_none()
        {
            assigned[idx] = Some(track_id);
        } else {
            fallback.push((tlwh, track_id));
        }
    }

    for (tlwh, track_id) in fallback {
        let best = raw_dets
            .iter()
            .enumerate()
            .filter(|(idx, _)| assigned[*idx].is_none())
            .map(|(idx, (det_tlwh, _, _))| (idx, tlwh_iou(tlwh, *det_tlwh)))
            .max_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((idx, iou)) = best
            && iou > 0.0
        {
            assigned[idx] = Some(track_id);
        }
    }
}

fn tlwh_iou(a: [f32; 4], b: [f32; 4]) -> f32 {
    let ax2 = a[0] + a[2];
    let ay2 = a[1] + a[3];
    let bx2 = b[0] + b[2];
    let by2 = b[1] + b[3];

    let ix1 = a[0].max(b[0]);
    let iy1 = a[1].max(b[1]);
    let ix2 = ax2.min(bx2);
    let iy2 = ay2.min(by2);

    let inter = (ix2 - ix1).max(0.0) * (iy2 - iy1).max(0.0);
    if inter <= 0.0 {
        return 0.0;
    }
    let area_a = a[2].max(0.0) * a[3].max(0.0);
    let area_b = b[2].max(0.0) * b[3].max(0.0);
    inter / (area_a + area_b - inter).max(1e-6)
}
