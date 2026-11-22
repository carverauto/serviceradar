//! Multi-object tracker (`trackforge`-powered) with explicit track lifecycle state machine,
//! per-track best keyframe selection, dwell timing, and structured [`DetectionEvent`] emission.

use crate::attributes::VisualAttributes;
use crate::detector::{Detection, ObjectCategory};
use crate::error::MediaCoreError;
use crate::frame::RgbFrame;
use crate::thumbnail::EncodedThumbnail;
use core::fmt::{self, Display, Formatter};
use core::str::FromStr;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use trackforge::trackers::botsort::BotSort;
use trackforge::trackers::byte_track::ByteTrack;
use trackforge::trackers::deep_ocsort::DeepOcSortTracker;
use trackforge::trackers::deepsort::{Metric, NearestNeighborDistanceMetric};
use uuid::Uuid;

const DEFAULT_CONFIDENCE_THRESH: f32 = 0.35;
const DEFAULT_TRACK_BUFFER_FRAMES: usize = 30;
const DEFAULT_MAX_CLOSED_TRACKS: usize = 256;
const DEFAULT_MATCH_IOU_DIST: f32 = 0.85;
const DEFAULT_APPEARANCE_COSINE_DIST: f32 = 0.35;
const BOTSORT_PROXIMITY_IOU_DIST: f32 = 0.90;
const DEEP_OCSORT_MIN_IOU: f32 = 0.15;
const DEEP_OCSORT_DELTA_T: usize = 3;
const DEEP_OCSORT_INERTIA: f32 = 0.2;
const DEEP_OCSORT_APPEARANCE_WEIGHT: f32 = 0.5;
const DEEP_OCSORT_NN_BUDGET: usize = 32;

/// Configurable multi-object tracker algorithm backed by `trackforge`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackerMode {
    #[default]
    #[serde(rename = "bytetrack")]
    ByteTrack,
    #[serde(rename = "botsort")]
    BotSort,
    #[serde(rename = "deep_ocsort")]
    DeepOcSort,
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
    type Err = MediaCoreError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "bytetrack" | "byte_track" => Ok(Self::ByteTrack),
            "botsort" | "bot_sort" => Ok(Self::BotSort),
            "deep_ocsort" | "deepocsort" => Ok(Self::DeepOcSort),
            "off" | "none" | "disabled" => Ok(Self::Off),
            other => Err(MediaCoreError::invalid_configuration(format!(
                "unsupported tracker '{other}'; expected 'bytetrack', 'botsort', 'deep_ocsort', or 'off'"
            ))),
        }
    }
}

/// Explicit track lifecycle state (`New` -> `Active` -> `Lost` -> `Closed`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackState {
    /// Track has been observed fewer than `min_hits_to_activate` times.
    New,
    /// Track is confirmed and currently observed.
    Active,
    /// Track was previously active/new but missed on the most recent frame(s).
    Lost,
    /// Track exceeded `max_lost_frames`/`max_lost_ms` or was capacity-evicted and has exited.
    Closed,
}

fn default_max_closed_tracks() -> usize {
    DEFAULT_MAX_CLOSED_TRACKS
}

/// Configuration for [`MultiObjectTracker`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackerConfig {
    pub mode: TrackerMode,
    /// Consecutive/total hits required to promote a `New` track to `Active` (default `2`).
    pub min_hits_to_activate: u32,
    /// Maximum consecutive missed frames before a `Lost` track transitions to `Closed` (default `30`).
    pub max_lost_frames: u32,
    /// Maximum idle elapsed milliseconds before a `Lost` track transitions to `Closed` (default `30_000`).
    pub max_lost_ms: u64,
    /// Hard cap on live tracked IDs retained in memory (default `128`).
    pub max_tracks: usize,
    /// Maximum closed track summaries retained in the bounded ring buffer (default `256`).
    #[serde(default = "default_max_closed_tracks")]
    pub max_closed_tracks: usize,
    /// Minimum confidence passed to `trackforge` high-score association (default `0.35`).
    pub confidence_threshold: f32,
}

impl Default for TrackerConfig {
    fn default() -> Self {
        Self {
            mode: TrackerMode::ByteTrack,
            min_hits_to_activate: 2,
            max_lost_frames: 30,
            max_lost_ms: 30_000,
            max_tracks: 128,
            max_closed_tracks: DEFAULT_MAX_CLOSED_TRACKS,
            confidence_threshold: DEFAULT_CONFIDENCE_THRESH,
        }
    }
}

/// Best keyframe observation selected for a track (`bbox_area * confidence * sharpness_factor`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BestKeyframeSnapshot {
    pub timestamp_ms: u64,
    pub bbox: [f32; 4],
    pub confidence: f32,
    pub quality_score: f32,
    pub attributes: Option<VisualAttributes>,
}

/// Computes the base crop quality score: `confidence * normalized_box_area * sharpness_factor`.
pub fn keyframe_quality_score(confidence: f32, bbox: [f32; 4], sharpness_factor: f32) -> f32 {
    let width = (bbox[2] - bbox[0]).max(0.0);
    let height = (bbox[3] - bbox[1]).max(0.0);
    confidence.max(0.0) * (width * height) * sharpness_factor.max(0.1)
}

/// Public summary snapshot of a tracked object.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackSummary {
    pub track_id: u64,
    pub category: ObjectCategory,
    pub state: TrackState,
    pub first_seen_ms: u64,
    pub last_seen_ms: u64,
    pub dwell_ms: u64,
    pub frame_count: u32,
    pub peak_confidence: f32,
    pub last_bbox: [f32; 4],
    pub best_keyframe: BestKeyframeSnapshot,
}

/// Kind of structured detection/tracking event emitted by the tracker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DetectionEventKind {
    TrackEntered,
    TrackUpdated,
    TrackExited,
    MotionDetected,
}

/// Structured event emitted on track lifecycle transitions or motion triggers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetectionEvent {
    pub event_id: Uuid,
    pub camera_id: String,
    pub kind: DetectionEventKind,
    pub track_id: Option<u64>,
    pub category: ObjectCategory,
    pub confidence: f32,
    pub bbox: [f32; 4],
    pub attributes: Option<VisualAttributes>,
    pub timestamp_ms: u64,
    pub first_seen_ms: u64,
    pub last_seen_ms: u64,
    pub dwell_ms: u64,
    pub thumbnail: Option<EncodedThumbnail>,
}

/// Output returned by [`MultiObjectTracker::update`].
#[derive(Debug, Clone, PartialEq)]
pub struct TrackerStepOutput {
    /// Assigned `track_id` parallel to the input `detections` slice.
    pub assigned_track_ids: Vec<Option<u64>>,
    /// Structured events emitted during this step (`TrackEntered`, `TrackExited`).
    pub events: Vec<DetectionEvent>,
    /// Track IDs that achieved a new best-keyframe quality score on this frame.
    pub improved_best_keyframe_tracks: Vec<u64>,
}

#[derive(Debug, Clone)]
struct TrackRecord {
    raw_track_id: u64,
    category: ObjectCategory,
    state: TrackState,
    first_seen_ms: u64,
    last_seen_ms: u64,
    frame_count: u32,
    missed_frames: u32,
    peak_confidence: f32,
    last_bbox: [f32; 4],
    best_keyframe: BestKeyframeSnapshot,
    best_keyframe_thumbnail: Option<EncodedThumbnail>,
    entered_emitted: bool,
}

impl TrackRecord {
    fn to_summary(&self, track_id: u64) -> TrackSummary {
        TrackSummary {
            track_id,
            category: self.category,
            state: self.state,
            first_seen_ms: self.first_seen_ms,
            last_seen_ms: self.last_seen_ms,
            dwell_ms: self.last_seen_ms.saturating_sub(self.first_seen_ms),
            frame_count: self.frame_count,
            peak_confidence: self.peak_confidence,
            last_bbox: self.last_bbox,
            best_keyframe: self.best_keyframe.clone(),
        }
    }
}

enum TrackerEngine {
    Off,
    ByteTrack(ByteTrack),
    BotSort(BotSort),
    DeepOcSort(DeepOcSortTracker),
}

/// Stateful per-camera or per-clip multi-object tracker powered by `trackforge`.
pub struct MultiObjectTracker {
    camera_id: String,
    config: TrackerConfig,
    engine: TrackerEngine,
    next_local_track_id: u64,
    active_raw_to_local: HashMap<u64, u64>,
    tracks: BTreeMap<u64, TrackRecord>,
    closed_tracks: VecDeque<TrackSummary>,
}

impl fmt::Debug for MultiObjectTracker {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.debug_struct("MultiObjectTracker")
            .field("camera_id", &self.camera_id)
            .field("mode", &self.config.mode)
            .field("live_tracks", &self.tracks.len())
            .field("closed_tracks", &self.closed_tracks.len())
            .finish()
    }
}

impl MultiObjectTracker {
    pub fn new(camera_id: impl Into<String>, config: TrackerConfig) -> Self {
        let thresh = config.confidence_threshold.clamp(0.01, 0.99);
        let buf_frames = (config.max_lost_frames as usize).max(DEFAULT_TRACK_BUFFER_FRAMES);
        let engine = match config.mode {
            TrackerMode::Off => TrackerEngine::Off,
            TrackerMode::ByteTrack => TrackerEngine::ByteTrack(ByteTrack::new(
                thresh,
                buf_frames,
                DEFAULT_MATCH_IOU_DIST,
                thresh,
            )),
            TrackerMode::BotSort => TrackerEngine::BotSort(BotSort::new(
                thresh,
                buf_frames,
                DEFAULT_MATCH_IOU_DIST,
                thresh,
                BOTSORT_PROXIMITY_IOU_DIST,
                DEFAULT_APPEARANCE_COSINE_DIST,
            )),
            TrackerMode::DeepOcSort => {
                let metric = NearestNeighborDistanceMetric::new(
                    Metric::Cosine,
                    DEFAULT_APPEARANCE_COSINE_DIST,
                    Some(DEEP_OCSORT_NN_BUDGET),
                );
                TrackerEngine::DeepOcSort(DeepOcSortTracker::new(
                    buf_frames,
                    1,
                    DEEP_OCSORT_MIN_IOU,
                    DEEP_OCSORT_DELTA_T,
                    DEEP_OCSORT_INERTIA,
                    DEEP_OCSORT_APPEARANCE_WEIGHT,
                    DEFAULT_APPEARANCE_COSINE_DIST,
                    metric,
                ))
            }
        };

        Self {
            camera_id: camera_id.into(),
            config,
            engine,
            next_local_track_id: 1,
            active_raw_to_local: HashMap::new(),
            tracks: BTreeMap::new(),
            closed_tracks: VecDeque::new(),
        }
    }

    pub fn camera_id(&self) -> &str {
        &self.camera_id
    }

    pub fn config(&self) -> &TrackerConfig {
        &self.config
    }

    /// Advances the tracker by one frame, associating `detections` via `trackforge`,
    /// updating lifecycle states (`New` -> `Active` -> `Lost` -> `Closed`), tracking per-track
    /// best keyframes, and emitting [`DetectionEvent`]s.
    pub fn update(
        &mut self,
        frame_dims: (u32, u32),
        timestamp_ms: u64,
        detections: &[Detection],
        attributes: Option<&[VisualAttributes]>,
        embeddings: Option<&[Vec<f32>]>,
        frame_for_sharpness: Option<&RgbFrame>,
    ) -> TrackerStepOutput {
        let (frame_width, frame_height) = frame_dims;
        let mut assigned = vec![None; detections.len()];
        let mut events = Vec::new();
        let mut improved_best_keyframe_tracks = Vec::new();

        if matches!(self.engine, TrackerEngine::Off) {
            return TrackerStepOutput {
                assigned_track_ids: assigned,
                events,
                improved_best_keyframe_tracks,
            };
        }

        let fw = frame_width.max(1) as f32;
        let fh = frame_height.max(1) as f32;
        let raw_dets: Vec<([f32; 4], f32, i64)> = detections
            .iter()
            .map(|det| {
                let [x1, y1, x2, y2] = det.bbox;
                let tlwh = [
                    x1 * fw,
                    y1 * fh,
                    (x2 - x1).max(1e-4) * fw,
                    (y2 - y1).max(1e-4) * fh,
                ];
                (tlwh, det.confidence, i64::from(det.label.class_id()))
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

        let mut seen_this_frame = HashSet::with_capacity(assigned.len());
        let min_hits = self.config.min_hits_to_activate.max(1);

        for (idx, (det, maybe_raw_tid)) in detections.iter().zip(assigned.iter_mut()).enumerate() {
            let Some(raw_tid) = *maybe_raw_tid else {
                continue;
            };
            let tid = self.resolve_local_track_id(raw_tid);
            *maybe_raw_tid = Some(tid);
            seen_this_frame.insert(tid);
            let attrs = attributes.and_then(|s| s.get(idx)).cloned();
            let sharpness = frame_for_sharpness
                .map(|f| f.crop_sharpness_factor(det.bbox))
                .unwrap_or(1.0);
            let quality = keyframe_quality_score(det.confidence, det.bbox, sharpness);

            let snapshot = BestKeyframeSnapshot {
                timestamp_ms,
                bbox: det.bbox,
                confidence: det.confidence,
                quality_score: quality,
                attributes: attrs.clone(),
            };

            let rec = self.tracks.entry(tid).or_insert_with(|| TrackRecord {
                raw_track_id: raw_tid,
                category: det.label,
                state: if min_hits <= 1 {
                    TrackState::Active
                } else {
                    TrackState::New
                },
                first_seen_ms: timestamp_ms,
                last_seen_ms: timestamp_ms,
                frame_count: 0,
                missed_frames: 0,
                peak_confidence: det.confidence,
                last_bbox: det.bbox,
                best_keyframe: snapshot.clone(),
                best_keyframe_thumbnail: None,
                entered_emitted: false,
            });

            rec.frame_count = rec.frame_count.saturating_add(1);
            rec.missed_frames = 0;
            rec.first_seen_ms = rec.first_seen_ms.min(timestamp_ms);
            rec.last_seen_ms = rec.last_seen_ms.max(timestamp_ms);
            rec.last_bbox = det.bbox;

            if det.confidence > rec.peak_confidence {
                rec.peak_confidence = det.confidence;
                rec.category = det.label;
            }
            if rec.frame_count == 1 || quality > rec.best_keyframe.quality_score + 1e-6 {
                rec.best_keyframe = snapshot;
                rec.best_keyframe_thumbnail = None;
                improved_best_keyframe_tracks.push(tid);
            }

            if rec.frame_count >= min_hits {
                rec.state = TrackState::Active;
            } else {
                rec.state = TrackState::New;
            }

            if rec.state == TrackState::Active && !rec.entered_emitted {
                rec.entered_emitted = true;
                events.push(DetectionEvent {
                    event_id: Uuid::new_v4(),
                    camera_id: self.camera_id.clone(),
                    kind: DetectionEventKind::TrackEntered,
                    track_id: Some(tid),
                    category: rec.category,
                    confidence: det.confidence,
                    bbox: det.bbox,
                    attributes: attrs,
                    timestamp_ms,
                    first_seen_ms: rec.first_seen_ms,
                    last_seen_ms: rec.last_seen_ms,
                    dwell_ms: rec.last_seen_ms.saturating_sub(rec.first_seen_ms),
                    thumbnail: None,
                });
            }
        }

        // Advance missed tracks -> Lost -> Closed
        let mut to_close = Vec::new();
        for (&tid, rec) in &mut self.tracks {
            if seen_this_frame.contains(&tid) {
                continue;
            }
            rec.missed_frames = rec.missed_frames.saturating_add(1);
            let idle_ms = timestamp_ms.saturating_sub(rec.last_seen_ms);
            if rec.missed_frames >= self.config.max_lost_frames
                || (self.config.max_lost_ms > 0 && idle_ms >= self.config.max_lost_ms)
            {
                to_close.push(tid);
            } else {
                rec.state = TrackState::Lost;
            }
        }

        for tid in to_close {
            self.close_track(tid, timestamp_ms, &mut events);
        }

        // Enforce bounded live track capacity by evicting oldest idle tracks
        while self.tracks.len() > self.config.max_tracks {
            let oldest_tid = self
                .tracks
                .iter()
                .min_by_key(|(_, rec)| rec.last_seen_ms)
                .map(|(&tid, _)| tid);
            let Some(tid) = oldest_tid else {
                break;
            };
            self.close_track(tid, timestamp_ms, &mut events);
        }

        TrackerStepOutput {
            assigned_track_ids: assigned,
            events,
            improved_best_keyframe_tracks,
        }
    }

    /// Advances tracker time without stepping `trackforge` association (e.g. on gate-skipped
    /// frames), closing any `Lost` tracks whose idle duration meets or exceeds `max_lost_ms`
    /// and returning any emitted `TrackExited` events. Tracks present on the last admitted
    /// frame (`New`/`Active`, `missed_frames == 0`) remain open across skipped static scenes.
    pub fn advance_time(&mut self, timestamp_ms: u64) -> Vec<DetectionEvent> {
        if matches!(self.engine, TrackerEngine::Off) || self.config.max_lost_ms == 0 {
            return Vec::new();
        }

        let to_close: Vec<u64> = self
            .tracks
            .iter()
            .filter_map(|(&tid, rec)| {
                if rec.state != TrackState::Lost || rec.missed_frames == 0 {
                    return None;
                }
                let idle_ms = timestamp_ms.saturating_sub(rec.last_seen_ms);
                (idle_ms >= self.config.max_lost_ms).then_some(tid)
            })
            .collect();

        let mut events = Vec::new();
        for tid in to_close {
            self.close_track(tid, timestamp_ms, &mut events);
        }
        events
    }

    /// Stores the encoded thumbnail for a live track's current best keyframe.
    pub fn set_best_keyframe_thumbnail(
        &mut self,
        track_id: u64,
        thumbnail: EncodedThumbnail,
    ) -> bool {
        let Some(rec) = self.tracks.get_mut(&track_id) else {
            return false;
        };
        rec.best_keyframe_thumbnail = Some(thumbnail);
        true
    }

    /// Returns live (non-closed) track summaries ordered by `track_id`.
    pub fn live_summaries(&self) -> Vec<TrackSummary> {
        self.tracks
            .iter()
            .map(|(&tid, rec)| rec.to_summary(tid))
            .collect()
    }

    /// Returns retained closed track summaries (bounded by `max_closed_tracks`).
    pub fn closed_summaries(&self) -> &VecDeque<TrackSummary> {
        &self.closed_tracks
    }

    /// Drains and returns all retained closed track summaries in close order.
    pub fn take_closed_summaries(&mut self) -> Vec<TrackSummary> {
        self.closed_tracks.drain(..).collect()
    }

    /// Returns all known tracks (live + retained closed) ordered by `track_id`.
    pub fn all_summaries(&self) -> Vec<TrackSummary> {
        let mut all: Vec<TrackSummary> = self.closed_tracks.iter().cloned().collect();
        all.extend(self.live_summaries());
        all.sort_by_key(|s| s.track_id);
        all
    }

    fn resolve_local_track_id(&mut self, raw_tid: u64) -> u64 {
        if let Some(&local_tid) = self.active_raw_to_local.get(&raw_tid) {
            return local_tid;
        }
        let local_tid = self.next_local_track_id;
        self.next_local_track_id = self.next_local_track_id.saturating_add(1);
        self.active_raw_to_local.insert(raw_tid, local_tid);
        local_tid
    }

    fn close_track(&mut self, tid: u64, exit_timestamp_ms: u64, events: &mut Vec<DetectionEvent>) {
        let Some(mut rec) = self.tracks.remove(&tid) else {
            return;
        };
        if self.active_raw_to_local.get(&rec.raw_track_id) == Some(&tid) {
            self.active_raw_to_local.remove(&rec.raw_track_id);
        }
        rec.state = TrackState::Closed;
        let summary = rec.to_summary(tid);
        if rec.entered_emitted {
            events.push(DetectionEvent {
                event_id: Uuid::new_v4(),
                camera_id: self.camera_id.clone(),
                kind: DetectionEventKind::TrackExited,
                track_id: Some(tid),
                category: summary.category,
                confidence: summary.peak_confidence,
                bbox: summary.best_keyframe.bbox,
                attributes: summary.best_keyframe.attributes.clone(),
                timestamp_ms: exit_timestamp_ms,
                first_seen_ms: summary.first_seen_ms,
                last_seen_ms: summary.last_seen_ms,
                dwell_ms: summary.dwell_ms,
                thumbnail: rec.best_keyframe_thumbnail,
            });
        }
        self.record_closed_summary(summary);
    }

    fn record_closed_summary(&mut self, summary: TrackSummary) {
        let cap = self.config.max_closed_tracks;
        if cap == 0 {
            return;
        }
        while self.closed_tracks.len() >= cap {
            self.closed_tracks.pop_front();
        }
        self.closed_tracks.push_back(summary);
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

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_thumb(tag: &str) -> EncodedThumbnail {
        EncodedThumbnail {
            width: 32,
            height: 18,
            quality: 75,
            jpeg_bytes: vec![0xFF, 0xD8, 0xFF, 0xD9],
            sha256_hex: tag.to_string(),
        }
    }

    #[test]
    fn tracker_lifecycle_new_active_lost_closed_and_best_keyframe() {
        let mut tracker = MultiObjectTracker::new(
            "cam-synth-0001",
            TrackerConfig {
                mode: TrackerMode::ByteTrack,
                min_hits_to_activate: 2,
                max_lost_frames: 2,
                max_lost_ms: 10_000,
                max_tracks: 32,
                max_closed_tracks: 256,
                confidence_threshold: 0.35,
            },
        );

        // Frame 0: small person bbox -> New (no TrackEntered yet)
        let d0 = [Detection::new(
            0,
            ObjectCategory::Person,
            0.70,
            [0.10, 0.20, 0.20, 0.50],
        )];
        let out0 = tracker.update((640, 360), 1_000, &d0, None, None, None);
        let tid = out0.assigned_track_ids[0].expect("track assigned");
        assert!(out0.events.is_empty());
        assert_eq!(tracker.live_summaries()[0].state, TrackState::New);

        // Frame 1: larger, higher-confidence bbox -> Active + TrackEntered + new best keyframe
        let d1 = [Detection::new(
            0,
            ObjectCategory::Person,
            0.94,
            [0.12, 0.18, 0.28, 0.62],
        )];
        let out1 = tracker.update((640, 360), 2_000, &d1, None, None, None);
        assert_eq!(out1.assigned_track_ids[0], Some(tid));
        assert_eq!(out1.events.len(), 1);
        assert_eq!(out1.events[0].kind, DetectionEventKind::TrackEntered);
        assert!(out1.improved_best_keyframe_tracks.contains(&tid));
        assert_eq!(tracker.live_summaries()[0].state, TrackState::Active);
        assert_eq!(
            tracker.live_summaries()[0].best_keyframe.timestamp_ms,
            2_000
        );

        // Frame 2: empty -> Lost
        let out2 = tracker.update((640, 360), 3_000, &[], None, None, None);
        assert!(out2.events.is_empty());
        assert_eq!(tracker.live_summaries()[0].state, TrackState::Lost);

        // Frame 3: empty -> Closed + TrackExited
        let out3 = tracker.update((640, 360), 4_000, &[], None, None, None);
        assert_eq!(out3.events.len(), 1);
        assert_eq!(out3.events[0].kind, DetectionEventKind::TrackExited);
        assert_eq!(out3.events[0].track_id, Some(tid));
        assert_eq!(out3.events[0].first_seen_ms, 1_000);
        assert_eq!(out3.events[0].last_seen_ms, 2_000);
        assert_eq!(out3.events[0].dwell_ms, 1_000);
        assert!(tracker.live_summaries().is_empty());
        assert_eq!(tracker.closed_summaries().len(), 1);
        assert_eq!(tracker.closed_summaries()[0].state, TrackState::Closed);
    }

    #[test]
    fn closed_tracks_are_capped_and_take_closed_summaries_drains() {
        let mut tracker = MultiObjectTracker::new(
            "cam-synth-cap-01",
            TrackerConfig {
                mode: TrackerMode::ByteTrack,
                min_hits_to_activate: 1,
                max_lost_frames: 1,
                max_lost_ms: 10_000,
                max_tracks: 32,
                max_closed_tracks: 3,
                confidence_threshold: 0.35,
            },
        );

        let mut closed_ids = Vec::new();
        for i in 0..6u64 {
            let x1 = 0.05 + (i as f32) * 0.14;
            let det = [Detection::new(
                0,
                ObjectCategory::Person,
                0.90,
                [x1, 0.20, x1 + 0.10, 0.60],
            )];
            let appear = tracker.update((640, 360), i * 2_000 + 1_000, &det, None, None, None);
            let tid = appear.assigned_track_ids[0].expect("track assigned");
            let exit = tracker.update((640, 360), i * 2_000 + 2_000, &[], None, None, None);
            assert_eq!(exit.events.len(), 1);
            assert_eq!(exit.events[0].kind, DetectionEventKind::TrackExited);
            assert_eq!(exit.events[0].track_id, Some(tid));
            closed_ids.push(tid);
        }

        assert_eq!(tracker.closed_summaries().len(), 3);
        let retained_ids: Vec<u64> = tracker
            .closed_summaries()
            .iter()
            .map(|s| s.track_id)
            .collect();
        assert_eq!(retained_ids, closed_ids[3..6]);
        assert_eq!(tracker.all_summaries().len(), 3);

        let drained = tracker.take_closed_summaries();
        let drained_ids: Vec<u64> = drained.iter().map(|s| s.track_id).collect();
        assert_eq!(drained_ids, closed_ids[3..6]);
        assert!(tracker.closed_summaries().is_empty());
        assert!(tracker.take_closed_summaries().is_empty());

        let mut zero_cap = MultiObjectTracker::new(
            "cam-synth-cap-00",
            TrackerConfig {
                max_lost_frames: 1,
                max_closed_tracks: 0,
                ..TrackerConfig::default()
            },
        );
        let det = [Detection::new(
            0,
            ObjectCategory::Person,
            0.90,
            [0.20, 0.20, 0.40, 0.70],
        )];
        zero_cap.update((640, 360), 1_000, &det, None, None, None);
        zero_cap.update((640, 360), 2_000, &[], None, None, None);
        assert!(zero_cap.closed_summaries().is_empty());
    }

    #[test]
    fn reassociated_raw_track_id_after_close_gets_fresh_monotonic_local_id() {
        let mut tracker = MultiObjectTracker::new(
            "cam-synth-reentry-01",
            TrackerConfig {
                mode: TrackerMode::ByteTrack,
                min_hits_to_activate: 1,
                max_lost_frames: 30,
                max_lost_ms: 5_000,
                max_tracks: 32,
                max_closed_tracks: 32,
                confidence_threshold: 0.35,
            },
        );

        let bbox = [0.20, 0.20, 0.40, 0.70];
        let det = [Detection::new(0, ObjectCategory::Person, 0.92, bbox)];

        let out0 = tracker.update((640, 360), 1_000, &det, None, None, None);
        let tid1 = out0.assigned_track_ids[0].expect("first track assigned");
        assert_eq!(out0.events.len(), 1);
        assert_eq!(out0.events[0].kind, DetectionEventKind::TrackEntered);
        assert_eq!(out0.events[0].track_id, Some(tid1));

        // 1 missed frame moves trackforge's raw track into Lost (still buffered for 30 frames).
        let out1 = tracker.update((640, 360), 2_000, &[], None, None, None);
        assert!(out1.events.is_empty());

        // Close locally via max_lost_ms while trackforge still retains raw ID 1.
        let out2 = tracker.update((640, 360), 7_000, &[], None, None, None);
        assert_eq!(out2.events.len(), 1);
        assert_eq!(out2.events[0].kind, DetectionEventKind::TrackExited);
        assert_eq!(out2.events[0].track_id, Some(tid1));

        // Object reappears at identical position; trackforge re-associates raw ID 1.
        let out3 = tracker.update((640, 360), 8_000, &det, None, None, None);
        let tid2 = out3.assigned_track_ids[0].expect("second track assigned");
        assert!(
            tid2 > tid1,
            "re-associated raw track ID must receive a fresh monotonic local ID ({tid2} <= {tid1})"
        );
        assert_eq!(out3.events.len(), 1);
        assert_eq!(out3.events[0].kind, DetectionEventKind::TrackEntered);
        assert_eq!(out3.events[0].track_id, Some(tid2));

        let out4 = tracker.update((640, 360), 9_000, &[], None, None, None);
        assert!(out4.events.is_empty());
        assert_eq!(tracker.live_summaries()[0].state, TrackState::Lost);

        let exit2 = tracker.advance_time(14_000);
        assert_eq!(exit2.len(), 1);
        assert_eq!(exit2[0].kind, DetectionEventKind::TrackExited);
        assert_eq!(exit2[0].track_id, Some(tid2));

        let closed_ids: Vec<u64> = tracker
            .closed_summaries()
            .iter()
            .map(|s| s.track_id)
            .collect();
        assert_eq!(closed_ids, vec![tid1, tid2]);
    }

    #[test]
    fn capacity_eviction_emits_track_exited_with_stored_best_keyframe_thumbnail() {
        let mut tracker = MultiObjectTracker::new(
            "cam-synth-evict-01",
            TrackerConfig {
                mode: TrackerMode::ByteTrack,
                min_hits_to_activate: 1,
                max_lost_frames: 30,
                max_lost_ms: 60_000,
                max_tracks: 2,
                max_closed_tracks: 32,
                confidence_threshold: 0.35,
            },
        );

        let det_a = Detection::new(0, ObjectCategory::Person, 0.91, [0.05, 0.20, 0.20, 0.70]);
        let det_b = Detection::new(0, ObjectCategory::Person, 0.90, [0.40, 0.20, 0.55, 0.70]);
        let det_c = Detection::new(0, ObjectCategory::Person, 0.92, [0.75, 0.20, 0.90, 0.70]);

        let out0 = tracker.update((640, 360), 1_000, &[det_a], None, None, None);
        let tid_a = out0.assigned_track_ids[0].expect("track A");
        let thumb_a = synthetic_thumb("best-keyframe-track-a");
        assert!(tracker.set_best_keyframe_thumbnail(tid_a, thumb_a.clone()));

        let out1 = tracker.update(
            (640, 360),
            2_000,
            std::slice::from_ref(&det_b),
            None,
            None,
            None,
        );
        let tid_b = out1.assigned_track_ids[0].expect("track B");
        assert_ne!(tid_a, tid_b);

        // Introducing track C pushes live count to 3 > max_tracks(2), evicting oldest idle track A.
        let out2 = tracker.update((640, 360), 3_000, &[det_b, det_c], None, None, None);
        let exit_ev = out2
            .events
            .iter()
            .find(|e| e.kind == DetectionEventKind::TrackExited)
            .expect("evicted entered track must emit TrackExited");
        assert_eq!(exit_ev.track_id, Some(tid_a));
        assert_eq!(exit_ev.timestamp_ms, 3_000);
        assert_eq!(exit_ev.thumbnail.as_ref(), Some(&thumb_a));
        assert_eq!(tracker.live_summaries().len(), 2);
        assert_eq!(tracker.closed_summaries().len(), 1);
        assert_eq!(tracker.closed_summaries()[0].track_id, tid_a);
        assert_eq!(tracker.closed_summaries()[0].state, TrackState::Closed);

        // Unconfirmed (New) tracks evicted before TrackEntered must not emit TrackExited.
        let mut unconfirmed = MultiObjectTracker::new(
            "cam-synth-evict-new",
            TrackerConfig {
                mode: TrackerMode::ByteTrack,
                min_hits_to_activate: 3,
                max_lost_frames: 30,
                max_lost_ms: 60_000,
                max_tracks: 1,
                max_closed_tracks: 16,
                confidence_threshold: 0.35,
            },
        );
        let d1 = Detection::new(0, ObjectCategory::Person, 0.90, [0.05, 0.20, 0.20, 0.70]);
        let d2 = Detection::new(0, ObjectCategory::Person, 0.90, [0.60, 0.20, 0.75, 0.70]);
        unconfirmed.update((640, 360), 1_000, &[d1], None, None, None);
        let evict_new = unconfirmed.update((640, 360), 2_000, &[d2], None, None, None);
        assert!(
            evict_new
                .events
                .iter()
                .all(|e| e.kind != DetectionEventKind::TrackExited)
        );
        assert_eq!(unconfirmed.closed_summaries().len(), 1);
    }

    #[test]
    fn advance_time_closes_expired_lost_tracks_and_preserves_active_stationary_tracks() {
        let mut tracker = MultiObjectTracker::new(
            "cam-synth-advance-01",
            TrackerConfig {
                mode: TrackerMode::ByteTrack,
                min_hits_to_activate: 1,
                max_lost_frames: 30,
                max_lost_ms: 10_000,
                max_tracks: 16,
                max_closed_tracks: 16,
                confidence_threshold: 0.35,
            },
        );

        let det = [Detection::new(
            0,
            ObjectCategory::Person,
            0.93,
            [0.25, 0.20, 0.45, 0.75],
        )];
        let out = tracker.update((640, 360), 1_000, &det, None, None, None);
        let tid = out.assigned_track_ids[0].expect("track assigned");
        let thumb = synthetic_thumb("best-keyframe-advance");
        assert!(tracker.set_best_keyframe_thumbnail(tid, thumb.clone()));

        // Active, never-missed track must survive advance_time well past max_lost_ms.
        assert!(tracker.advance_time(11_000).is_empty());
        assert!(tracker.advance_time(50_000).is_empty());
        assert_eq!(tracker.live_summaries().len(), 1);
        assert_eq!(tracker.live_summaries()[0].state, TrackState::Active);
        assert!(tracker.closed_summaries().is_empty());

        // Record a missed admitted frame so the track transitions to Lost.
        let miss = tracker.update((640, 360), 2_000, &[], None, None, None);
        assert!(miss.events.is_empty());
        assert_eq!(tracker.live_summaries()[0].state, TrackState::Lost);

        assert!(tracker.advance_time(10_999).is_empty());
        assert_eq!(tracker.live_summaries().len(), 1);

        let exit_events = tracker.advance_time(11_000);
        assert_eq!(exit_events.len(), 1);
        assert_eq!(exit_events[0].kind, DetectionEventKind::TrackExited);
        assert_eq!(exit_events[0].track_id, Some(tid));
        assert_eq!(exit_events[0].timestamp_ms, 11_000);
        assert_eq!(exit_events[0].thumbnail.as_ref(), Some(&thumb));
        assert!(tracker.live_summaries().is_empty());
        assert_eq!(tracker.closed_summaries().len(), 1);
    }

    #[test]
    fn tracker_modes_botsort_deep_ocsort_and_off_handle_lifecycle_and_embeddings() {
        use crate::error::MediaCoreErrorKind;

        assert!(matches!(
            TrackerMode::from_str("unknown_tracker").unwrap_err().kind(),
            MediaCoreErrorKind::InvalidConfiguration(_)
        ));
        assert_eq!(
            TrackerMode::from_str("botsort").unwrap(),
            TrackerMode::BotSort
        );
        assert_eq!(
            TrackerMode::from_str("deep_ocsort").unwrap(),
            TrackerMode::DeepOcSort
        );

        let emb = [vec![1.0f32, 0.0, 0.0, 0.0]];
        let d0 = [Detection::new(
            0,
            ObjectCategory::Person,
            0.90,
            [0.10, 0.20, 0.25, 0.70],
        )];
        let d1 = [Detection::new(
            0,
            ObjectCategory::Person,
            0.92,
            [0.13, 0.20, 0.28, 0.70],
        )];

        // BotSort & DeepOcSort both track consistently across movement and close cleanly on departure
        for mode in [TrackerMode::BotSort, TrackerMode::DeepOcSort] {
            let mut tracker = MultiObjectTracker::new(
                "cam-synth-mode-01",
                TrackerConfig {
                    mode,
                    min_hits_to_activate: 2,
                    max_lost_frames: 2,
                    max_lost_ms: 10_000,
                    max_tracks: 16,
                    max_closed_tracks: 16,
                    confidence_threshold: 0.35,
                },
            );

            let out0 = tracker.update((640, 360), 1_000, &d0, None, Some(emb.as_slice()), None);
            let tid = out0.assigned_track_ids[0].expect("mode must assign track id");
            assert_eq!(tracker.live_summaries()[0].state, TrackState::New);

            let out1 = tracker.update((640, 360), 2_000, &d1, None, Some(emb.as_slice()), None);
            assert_eq!(out1.assigned_track_ids[0], Some(tid));
            assert_eq!(out1.events.len(), 1);
            assert_eq!(out1.events[0].kind, DetectionEventKind::TrackEntered);

            // Departure -> Lost -> Closed
            let _ = tracker.update((640, 360), 3_000, &[], None, None, None);
            assert_eq!(tracker.live_summaries()[0].state, TrackState::Lost);
            let exit = tracker.update((640, 360), 4_000, &[], None, None, None);
            assert_eq!(exit.events.len(), 1);
            assert_eq!(exit.events[0].kind, DetectionEventKind::TrackExited);
            assert_eq!(exit.events[0].track_id, Some(tid));
        }

        // TrackerMode::Off emits no IDs, no events, and retains no tracks
        let mut off = MultiObjectTracker::new(
            "cam-synth-off-01",
            TrackerConfig {
                mode: TrackerMode::Off,
                ..TrackerConfig::default()
            },
        );
        let out = off.update((640, 360), 1_000, &d0, None, None, None);
        assert_eq!(out.assigned_track_ids, vec![None]);
        assert!(out.events.is_empty());
        assert!(off.advance_time(50_000).is_empty());
        assert!(off.all_summaries().is_empty());
    }
}
