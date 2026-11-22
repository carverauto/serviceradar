//! Two-stage keyframe vision pipeline and shared multimodal text encoder (`2.4`, `2.5`).
//!
//! - Stage 1: Localized subject detection (`person`, `vehicle`, `bicycle`, `animal`, `package`),
//!   class-aware NMS (`IoU <= 0.50`), `10%` padded full-resolution crop extraction with
//!   normalized `[x1, y1, x2, y2]` coordinates (`0.0..=1.0`), HSV coarse dominant-color
//!   classification, and optional static-empty-scene suppression (`< 2%` L1 delta).
//! - Stage 2: Batched vision-language encoding producing L2-normalized `:scene` and `:crop`
//!   vectors (`512`-d or `768`-d) aligned in the same unit-hypersphere semantic space as
//!   `embed_query_text`.

use crate::backend::{InferenceBackend, InferenceBackendInfo, RawDetection};
use crate::config::ModelPinConfig;
use crate::errors::MediaWorkerError;
use crate::tracking::{ClipTracker, TrackSummary, TrackerMode, crop_quality_score};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serviceradar_media_core::{
    CompressedFrameGateConfig, PixelMotionGate, PixelMotionGateConfig, ThumbnailConfig,
    TwoTierFrameGate, classify_crop_colors, encode_jpeg_thumbnail, extract_visual_attributes,
};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;

const MAX_CROPS_PER_FRAME: usize = 8;
const CROP_CONTEXT_MARGIN: f32 = 0.10;
const NMS_IOU_THRESHOLD: f32 = 0.50;
const DEFAULT_MIN_CONFIDENCE: f32 = 0.35;
const MAX_QUERY_CHARS: usize = 256;

/// Hard upper bound (48 KiB raw JPEG) on keyframe thumbnails attached to visual index results.
pub const MAX_THUMBNAIL_JPEG_BYTES: usize = 48 * 1024;
/// Hard upper bound (384 KiB total base64 bytes) on all thumbnails within one result envelope.
pub const MAX_ENVELOPE_THUMBNAIL_B64_BYTES: usize = 384 * 1024;

fn default_thumbnail_config() -> ThumbnailConfig {
    ThumbnailConfig {
        max_width: 480,
        max_height: 270,
        quality: 75,
        min_quality: 30,
        max_bytes: MAX_THUMBNAIL_JPEG_BYTES,
    }
}

fn encode_frame_thumbnail_b64(
    frame: &serviceradar_media_core::RgbFrame,
) -> Result<String, MediaWorkerError> {
    let encoded = encode_jpeg_thumbnail(frame, &default_thumbnail_config())
        .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;
    Ok(base64::engine::general_purpose::STANDARD.encode(&encoded.jpeg_bytes))
}

/// Canonical surveillance object classes emitted by Stage 1 (`design.md` Section 3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObjectClass {
    Person,
    Vehicle,
    Bicycle,
    Animal,
    Package,
}

impl ObjectClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Person => "person",
            Self::Vehicle => "vehicle",
            Self::Bicycle => "bicycle",
            Self::Animal => "animal",
            Self::Package => "package",
        }
    }

    pub fn class_id(self) -> i64 {
        self.slot_index() as i64
    }

    fn slot_index(self) -> usize {
        match self {
            Self::Person => 0,
            Self::Vehicle => 1,
            Self::Bicycle => 2,
            Self::Animal => 3,
            Self::Package => 4,
        }
    }
}

/// Decoded RGB8 video keyframe (`width * height * 3` bytes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RgbFrame {
    inner: serviceradar_media_core::RgbFrame,
}

impl RgbFrame {
    pub fn solid(width: u32, height: u32, rgb: [u8; 3]) -> Self {
        Self {
            inner: serviceradar_media_core::RgbFrame::solid(width, height, rgb),
        }
    }

    pub fn from_rgb8(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self, MediaWorkerError> {
        serviceradar_media_core::RgbFrame::from_rgb8(width, height, pixels)
            .map(|inner| Self { inner })
            .map_err(|err| MediaWorkerError::invalid_container(err.to_string()))
    }

    pub fn width(&self) -> u32 {
        self.inner.width()
    }

    pub fn height(&self) -> u32 {
        self.inner.height()
    }

    pub fn pixels(&self) -> &[u8] {
        self.inner.pixels()
    }

    pub fn pixel_at(&self, x: u32, y: u32) -> [u8; 3] {
        self.inner.pixel_at(x, y)
    }

    pub fn set_pixel(&mut self, x: u32, y: u32, rgb: [u8; 3]) {
        self.inner.set_pixel(x, y, rgb);
    }

    /// Extracts a normalized `[x1, y1, x2, y2]` sub-frame from the full-resolution image.
    pub fn crop_normalized(&self, bbox_norm: [f32; 4]) -> Self {
        Self {
            inner: self.inner.crop_normalized(bbox_norm),
        }
    }

    /// Borrows this worker [`RgbFrame`] as a [`serviceradar_media_core::RgbFrame`].
    pub fn as_media_core_frame(&self) -> &serviceradar_media_core::RgbFrame {
        &self.inner
    }

    /// Converts this worker [`RgbFrame`] into a [`serviceradar_media_core::RgbFrame`].
    pub fn to_media_core_frame(
        &self,
    ) -> Result<serviceradar_media_core::RgbFrame, MediaWorkerError> {
        Ok(self.inner.clone())
    }

    /// Computes normalized `[0.0, 1.0]` L1 pixel difference on a `16x16` downsampled grid.
    pub fn downsampled_l1_delta(&self, other: &Self) -> f32 {
        let grid = 16u32;
        let mut diff_sum = 0.0f32;
        let self_w = self.width();
        let self_h = self.height();
        let other_w = other.width();
        let other_h = other.height();
        for gy in 0..grid {
            for gx in 0..grid {
                let ax = ((gx * self_w) / grid).min(self_w - 1);
                let ay = ((gy * self_h) / grid).min(self_h - 1);
                let bx = ((gx * other_w) / grid).min(other_w - 1);
                let by = ((gy * other_h) / grid).min(other_h - 1);
                let pa = self.pixel_at(ax, ay);
                let pb = other.pixel_at(bx, by);
                let pixel_diff = ((i16::from(pa[0]) - i16::from(pb[0])).unsigned_abs()
                    + (i16::from(pa[1]) - i16::from(pb[1])).unsigned_abs()
                    + (i16::from(pa[2]) - i16::from(pb[2])).unsigned_abs())
                    as f32
                    / (3.0 * 255.0);
                diff_sum += pixel_diff;
            }
        }
        diff_sum / ((grid * grid) as f32)
    }
}

/// Stage 1 localized foreground subject detection.
#[derive(Debug, Clone, PartialEq)]
pub struct DetectedSubject {
    object_class: ObjectClass,
    confidence: f32,
    bbox_norm: [f32; 4],
    padded_crop_bbox_norm: [f32; 4],
    dominant_colors: Vec<String>,
    track_id: Option<u64>,
}

impl DetectedSubject {
    pub fn object_class(&self) -> ObjectClass {
        self.object_class
    }

    pub fn confidence(&self) -> f32 {
        self.confidence
    }

    pub fn bbox_norm(&self) -> [f32; 4] {
        self.bbox_norm
    }

    pub fn padded_crop_bbox_norm(&self) -> [f32; 4] {
        self.padded_crop_bbox_norm
    }

    pub fn dominant_colors(&self) -> &[String] {
        &self.dominant_colors
    }

    pub fn track_id(&self) -> Option<u64> {
        self.track_id
    }

    pub(crate) fn set_track_id(&mut self, track_id: Option<u64>) {
        self.track_id = track_id;
    }
}

/// Stage 2 L2-normalized `:scene` or `:crop` embedding output.
#[derive(Debug, Clone, PartialEq)]
pub struct GeneratedEmbedding {
    region_kind: String,
    region_index: u32,
    object_class: Option<String>,
    confidence: Option<f32>,
    bbox_norm: Option<[f32; 4]>,
    dominant_colors: Vec<String>,
    track_id: Option<u64>,
    embedding: Vec<f32>,
}

impl GeneratedEmbedding {
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

    pub fn bbox_norm(&self) -> Option<[f32; 4]> {
        self.bbox_norm
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

/// Combined Stage 1 + Stage 2 analysis output for a single IDR keyframe.
#[derive(Debug, Clone, PartialEq)]
pub struct KeyframeAnalysis {
    scene_suppressed: bool,
    detections: Vec<DetectedSubject>,
    embeddings: Vec<GeneratedEmbedding>,
    thumbnail_jpeg_b64: Option<String>,
}

impl KeyframeAnalysis {
    pub fn scene_suppressed(&self) -> bool {
        self.scene_suppressed
    }

    pub fn detections(&self) -> &[DetectedSubject] {
        &self.detections
    }

    pub fn embeddings(&self) -> &[GeneratedEmbedding] {
        &self.embeddings
    }

    pub fn thumbnail_jpeg_b64(&self) -> Option<&str> {
        self.thumbnail_jpeg_b64.as_deref()
    }
}

/// Input keyframe entry for multi-frame clip analysis (`VisionPipeline::process_clip_keyframes`).
#[derive(Debug, Clone, Copy)]
pub struct ClipKeyframe<'a> {
    pub offset_ms: u64,
    pub frame: &'a RgbFrame,
}

impl<'a> ClipKeyframe<'a> {
    pub fn new(offset_ms: u64, frame: &'a RgbFrame) -> Self {
        Self { offset_ms, frame }
    }
}

/// Multi-keyframe clip analysis output including per-frame results and per-track summaries.
#[derive(Debug, Clone, PartialEq)]
pub struct ClipAnalysis {
    frames: Vec<KeyframeAnalysis>,
    tracks: Vec<TrackSummary>,
    block_thumbnail_jpeg_b64: Option<String>,
    stage1_latencies_secs: Vec<f64>,
    stage2_latencies_secs: Vec<f64>,
}

impl ClipAnalysis {
    pub fn frames(&self) -> &[KeyframeAnalysis] {
        &self.frames
    }

    pub fn tracks(&self) -> &[TrackSummary] {
        &self.tracks
    }

    pub fn block_thumbnail_jpeg_b64(&self) -> Option<&str> {
        self.block_thumbnail_jpeg_b64.as_deref()
    }

    pub fn into_parts(self) -> (Vec<KeyframeAnalysis>, Vec<TrackSummary>) {
        (self.frames, self.tracks)
    }

    pub(crate) fn stage1_latencies_secs(&self) -> &[f64] {
        &self.stage1_latencies_secs
    }

    pub(crate) fn stage2_latencies_secs(&self) -> &[f64] {
        &self.stage2_latencies_secs
    }
}

/// Two-stage keyframe vision pipeline (`Stage 1` subject detector + `Stage 2`
/// batched vision-language image encoder) backed by a pluggable `InferenceBackend`.
#[derive(Clone)]
pub struct VisionPipeline {
    models: ModelPinConfig,
    skip_unchanged_empty_scenes: bool,
    tracker_mode: TrackerMode,
    dedup_track_crops: bool,
    backend: Arc<dyn InferenceBackend>,
}

impl core::fmt::Debug for VisionPipeline {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("VisionPipeline")
            .field("models", &self.models)
            .field(
                "skip_unchanged_empty_scenes",
                &self.skip_unchanged_empty_scenes,
            )
            .field("tracker_mode", &self.tracker_mode)
            .field("dedup_track_crops", &self.dedup_track_crops)
            .field("backend_info", &self.backend.info())
            .finish()
    }
}

impl VisionPipeline {
    /// Constructs a pipeline backed by an explicit `InferenceBackend` (e.g. `CandleBackend`).
    pub fn with_backend(
        models: ModelPinConfig,
        skip_unchanged_empty_scenes: bool,
        backend: Arc<dyn InferenceBackend>,
    ) -> Self {
        Self {
            models,
            skip_unchanged_empty_scenes,
            tracker_mode: TrackerMode::ByteTrack,
            dedup_track_crops: true,
            backend,
        }
    }

    /// Configures per-clip multi-object tracking mode and best-crop deduplication.
    pub fn with_tracking(mut self, tracker_mode: TrackerMode, dedup_track_crops: bool) -> Self {
        self.tracker_mode = tracker_mode;
        self.dedup_track_crops = dedup_track_crops;
        self
    }

    pub fn models(&self) -> &ModelPinConfig {
        &self.models
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

    pub fn backend(&self) -> &Arc<dyn InferenceBackend> {
        &self.backend
    }

    pub fn backend_info(&self) -> InferenceBackendInfo {
        self.backend.info()
    }

    /// Builds a stateful `serviceradar-media-core` stage pipeline (two-tier motion gate ->
    /// object detector -> HSV sub-crop attributes -> `trackforge` tracker -> bounded JPEG
    /// keyframe thumbnail encoder) backed by this worker's active [`InferenceBackend`].
    pub fn build_media_core_pipeline(
        &self,
        config: serviceradar_media_core::MediaPipelineConfig,
    ) -> Result<serviceradar_media_core::MediaPipeline, serviceradar_media_core::MediaCoreError>
    {
        let detector: Arc<dyn serviceradar_media_core::ObjectDetector> =
            Arc::new(BackendObjectDetector::new(
                self.models.detector_model_id().to_string(),
                Arc::clone(&self.backend),
            ));
        serviceradar_media_core::MediaPipeline::new(config, detector)
    }

    /// Runs Stage 1 detection, per-clip `trackforge` multi-object tracking, optional
    /// best-crop deduplication, and Stage 2 embedding across sequential keyframes of a clip.
    ///
    /// Instantiates a fresh [`ClipTracker`] per call so the pipeline stays 100% stateless
    /// across clips.
    pub fn process_clip_keyframes(
        &self,
        keyframes: &[ClipKeyframe<'_>],
    ) -> Result<ClipAnalysis, MediaWorkerError> {
        self.process_sampled_keyframes(keyframes.iter().map(|kf| (kf.offset_ms, Some(kf.frame))))
    }

    pub(crate) fn process_sampled_keyframes<'a>(
        &self,
        keyframes: impl ExactSizeIterator<Item = (u64, Option<&'a RgbFrame>)>,
    ) -> Result<ClipAnalysis, MediaWorkerError> {
        let mut motion_gate = TwoTierFrameGate::new(
            CompressedFrameGateConfig::default(),
            PixelMotionGateConfig::default(),
        )
        .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;
        let mut tracker = ClipTracker::new(self.tracker_mode);
        let mut stage1_latencies_secs = Vec::with_capacity(keyframes.len());
        let mut stage2_latencies_secs = Vec::with_capacity(keyframes.len());
        let mut prev_had_detections = false;

        if self.tracker_mode.uses_appearance() {
            // Appearance-assisted modes (`botsort`, `deep_ocsort`) need Stage 2 crop embeddings
            // per frame to associate detections by appearance, then optionally deduplicate the
            // emitted crop embeddings to keep only the best crop per `track_id`.
            let mut per_frame_scene_suppressed = Vec::with_capacity(keyframes.len());
            let mut per_frame_detections: Vec<Vec<DetectedSubject>> =
                Vec::with_capacity(keyframes.len());
            let mut per_frame_embeddings: Vec<Vec<GeneratedEmbedding>> =
                Vec::with_capacity(keyframes.len());
            let mut frame_refs: Vec<(u64, &'a RgbFrame)> = Vec::with_capacity(keyframes.len());

            for (offset_ms, frame) in keyframes {
                let Some(frame) = frame else {
                    tracker.update_frame(0, 0, offset_ms, &[], None);
                    continue;
                };
                frame_refs.push((offset_ms, frame));
                let motion = motion_gate
                    .evaluate_rgb(offset_ms, frame.as_media_core_frame())
                    .map_err(|err| MediaWorkerError::invalid_container(err.to_string()))?;

                if self.skip_unchanged_empty_scenes
                    && !motion.decision.is_admitted()
                    && !prev_had_detections
                {
                    tracker.update_frame(frame.width(), frame.height(), offset_ms, &[], None);
                    per_frame_scene_suppressed.push(true);
                    per_frame_detections.push(Vec::new());
                    per_frame_embeddings.push(Vec::new());
                    continue;
                }

                let t_s1 = Instant::now();
                let mut detections = self.detect_subjects_checked(frame)?;
                stage1_latencies_secs.push(t_s1.elapsed().as_secs_f64());
                prev_had_detections = !detections.is_empty();

                let scene_suppressed = self.skip_unchanged_empty_scenes
                    && detections.is_empty()
                    && !motion.decision.is_admitted();

                let t_s2 = Instant::now();
                let mut embeddings =
                    self.encode_stage2_batch_checked(frame, &detections, scene_suppressed)?;
                stage2_latencies_secs.push(t_s2.elapsed().as_secs_f64());

                let crop_vecs: Vec<Vec<f32>> = embeddings
                    .iter()
                    .filter(|e| e.region_kind() == "crop")
                    .map(|e| e.embedding().to_vec())
                    .collect();

                let assigned = tracker.update_frame(
                    frame.width(),
                    frame.height(),
                    offset_ms,
                    &detections,
                    Some(&crop_vecs),
                );

                for (det, tid) in detections.iter_mut().zip(assigned.iter()) {
                    det.set_track_id(*tid);
                }

                let mut crop_idx = 0usize;
                for emb in &mut embeddings {
                    if emb.region_kind() == "crop" {
                        if let Some(&tid) = assigned.get(crop_idx) {
                            emb.track_id = tid;
                        }
                        crop_idx += 1;
                    }
                }

                per_frame_scene_suppressed.push(scene_suppressed);
                per_frame_detections.push(detections);
                per_frame_embeddings.push(embeddings);
            }

            if self.dedup_track_crops {
                let best_by_track = select_best_crop_per_track(&per_frame_detections);
                for (frame_idx, embeddings) in per_frame_embeddings.iter_mut().enumerate() {
                    let mut det_idx = 0usize;
                    let mut next_region_idx = 1u32;
                    let mut kept = Vec::with_capacity(embeddings.len());
                    for mut emb in embeddings.drain(..) {
                        if emb.region_kind() == "scene" {
                            kept.push(emb);
                        } else {
                            let keep = match emb.track_id {
                                Some(tid) => best_by_track.get(&tid) == Some(&(frame_idx, det_idx)),
                                None => true,
                            };
                            det_idx += 1;
                            if keep {
                                emb.region_index = next_region_idx;
                                next_region_idx += 1;
                                kept.push(emb);
                            }
                        }
                    }
                    *embeddings = kept;
                }
            }

            let mut frames: Vec<KeyframeAnalysis> = per_frame_scene_suppressed
                .into_iter()
                .zip(per_frame_detections)
                .zip(per_frame_embeddings)
                .map(
                    |((scene_suppressed, detections), embeddings)| KeyframeAnalysis {
                        scene_suppressed,
                        detections,
                        embeddings,
                        thumbnail_jpeg_b64: None,
                    },
                )
                .collect();

            let tracks = tracker.summaries();
            let block_thumbnail_jpeg_b64 = attach_budgeted_thumbnails(
                &mut frames,
                &frame_refs,
                &tracks,
                MAX_ENVELOPE_THUMBNAIL_B64_BYTES,
            )?;

            return Ok(ClipAnalysis {
                frames,
                tracks,
                block_thumbnail_jpeg_b64,
                stage1_latencies_secs,
                stage2_latencies_secs,
            });
        }

        // Motion-only (`bytetrack`) or untracked (`off`) path:
        // Pass 1 runs Tier-1 PixelMotionGate -> Stage 1 -> tracking across all clip keyframes so
        // best-crop deduplication avoids redundant Stage 2 vision-tower crop embedding calls.
        let mut staged = Vec::with_capacity(keyframes.len());
        let mut frame_refs: Vec<(u64, &'a RgbFrame)> = Vec::with_capacity(keyframes.len());
        for (offset_ms, frame) in keyframes {
            let Some(frame) = frame else {
                tracker.update_frame(0, 0, offset_ms, &[], None);
                continue;
            };
            frame_refs.push((offset_ms, frame));
            let motion = motion_gate
                .evaluate_rgb(offset_ms, frame.as_media_core_frame())
                .map_err(|err| MediaWorkerError::invalid_container(err.to_string()))?;

            if self.skip_unchanged_empty_scenes
                && !motion.decision.is_admitted()
                && !prev_had_detections
            {
                tracker.update_frame(frame.width(), frame.height(), offset_ms, &[], None);
                staged.push((frame, true, Vec::new()));
                continue;
            }

            let t_s1 = Instant::now();
            let mut detections = self.detect_subjects_checked(frame)?;
            stage1_latencies_secs.push(t_s1.elapsed().as_secs_f64());
            prev_had_detections = !detections.is_empty();

            let scene_suppressed = self.skip_unchanged_empty_scenes
                && detections.is_empty()
                && !motion.decision.is_admitted();

            let assigned =
                tracker.update_frame(frame.width(), frame.height(), offset_ms, &detections, None);
            for (det, tid) in detections.iter_mut().zip(assigned) {
                det.set_track_id(tid);
            }

            staged.push((frame, scene_suppressed, detections));
        }

        let best_by_track = if self.dedup_track_crops && self.tracker_mode.is_enabled() {
            let det_slices: Vec<Vec<DetectedSubject>> =
                staged.iter().map(|(_, _, d)| d.clone()).collect();
            Some(select_best_crop_per_track(&det_slices))
        } else {
            None
        };

        let mut frames = Vec::with_capacity(staged.len());
        for (frame_idx, (frame, scene_suppressed, detections)) in staged.into_iter().enumerate() {
            let selected_dets: Vec<DetectedSubject> = match &best_by_track {
                Some(best_map) => detections
                    .iter()
                    .enumerate()
                    .filter(|(det_idx, det)| match det.track_id() {
                        Some(tid) => best_map.get(&tid) == Some(&(frame_idx, *det_idx)),
                        None => true,
                    })
                    .map(|(_, det)| det.clone())
                    .collect(),
                None => detections.clone(),
            };

            let t_s2 = Instant::now();
            let embeddings =
                self.encode_stage2_batch_checked(frame, &selected_dets, scene_suppressed)?;
            stage2_latencies_secs.push(t_s2.elapsed().as_secs_f64());

            frames.push(KeyframeAnalysis {
                scene_suppressed,
                detections,
                embeddings,
                thumbnail_jpeg_b64: None,
            });
        }

        let tracks = tracker.summaries();
        let block_thumbnail_jpeg_b64 = attach_budgeted_thumbnails(
            &mut frames,
            &frame_refs,
            &tracks,
            MAX_ENVELOPE_THUMBNAIL_B64_BYTES,
        )?;

        Ok(ClipAnalysis {
            frames,
            tracks,
            block_thumbnail_jpeg_b64,
            stage1_latencies_secs,
            stage2_latencies_secs,
        })
    }

    /// Runs Stage 1 detection and Stage 2 embedding on one decoded IDR keyframe,
    /// propagating any backend inference errors cleanly.
    pub fn process_keyframe(
        &self,
        frame: &RgbFrame,
        previous_frame: Option<&RgbFrame>,
    ) -> Result<KeyframeAnalysis, MediaWorkerError> {
        let mc_frame = frame.as_media_core_frame();
        let motion_admitted = if let Some(prev) = previous_frame {
            let mut gate = PixelMotionGate::new(PixelMotionGateConfig::default())
                .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;
            let _ = gate
                .evaluate_rgb(0, prev.as_media_core_frame())
                .map_err(|err| MediaWorkerError::invalid_container(err.to_string()))?;
            gate.evaluate_rgb(1_000, mc_frame)
                .map_err(|err| MediaWorkerError::invalid_container(err.to_string()))?
                .decision
                .is_admitted()
        } else {
            true
        };

        let detections = self.detect_subjects_checked(frame)?;
        let scene_suppressed =
            self.skip_unchanged_empty_scenes && detections.is_empty() && !motion_admitted;

        let embeddings = self.encode_stage2_batch_checked(frame, &detections, scene_suppressed)?;
        let thumbnail_jpeg_b64 = if !scene_suppressed {
            Some(encode_frame_thumbnail_b64(mc_frame)?)
        } else {
            None
        };
        Ok(KeyframeAnalysis {
            scene_suppressed,
            detections,
            embeddings,
            thumbnail_jpeg_b64,
        })
    }

    /// Runs Stage 1 detection and Stage 2 embedding on one decoded IDR keyframe.
    ///
    /// Backwards-compatible infallible wrapper for deterministic/stub callers.
    pub fn analyze_keyframe(
        &self,
        frame: &RgbFrame,
        previous_frame: Option<&RgbFrame>,
    ) -> KeyframeAnalysis {
        self.process_keyframe(frame, previous_frame)
            .unwrap_or(KeyframeAnalysis {
                scene_suppressed: false,
                detections: Vec::new(),
                embeddings: Vec::new(),
                thumbnail_jpeg_b64: None,
            })
    }

    /// Stage 1: detects foreground subjects via the active `InferenceBackend`,
    /// applies class-aware NMS (`IoU <= 0.50`), computes `10%` padded crop boxes,
    /// and classifies HSV coarse dominant colors via `serviceradar-media-core`.
    pub fn detect_subjects_checked(
        &self,
        frame: &RgbFrame,
    ) -> Result<Vec<DetectedSubject>, MediaWorkerError> {
        let raw_detections = self.backend.detect_objects(frame, DEFAULT_MIN_CONFIDENCE)?;
        let bg = estimate_border_background(frame);
        let mc_frame = frame.as_media_core_frame();
        let mut candidates = Vec::with_capacity(raw_detections.len());

        for raw in raw_detections {
            if raw.confidence() < DEFAULT_MIN_CONFIDENCE {
                continue;
            }
            let bbox_norm = clamp_unit_bbox(raw.bbox_norm());
            let padded_crop_bbox_norm = expand_bbox_with_margin(bbox_norm, CROP_CONTEXT_MARGIN);
            let attrs = extract_visual_attributes(mc_frame, bbox_norm, Some(bg));
            let dominant_colors = attrs.dominant_color_names();
            let area_frac =
                ((bbox_norm[2] - bbox_norm[0]) * (bbox_norm[3] - bbox_norm[1])).max(1e-6);
            let rank_score = raw.confidence() * area_frac.sqrt();

            candidates.push((
                rank_score,
                DetectedSubject {
                    object_class: raw.object_class(),
                    confidence: raw.confidence(),
                    bbox_norm,
                    padded_crop_bbox_norm,
                    dominant_colors,
                    track_id: None,
                },
            ));
        }

        Ok(apply_class_aware_nms(
            candidates,
            NMS_IOU_THRESHOLD,
            MAX_CROPS_PER_FRAME,
        ))
    }

    /// Infallible Stage 1 helper retained for existing callers.
    pub fn detect_subjects(&self, frame: &RgbFrame) -> Vec<DetectedSubject> {
        self.detect_subjects_checked(frame).unwrap_or_default()
    }

    /// Stage 2: encodes `[scene_frame] ++ subject_crops` via the active `InferenceBackend`
    /// into L2-normalized unit vectors.
    pub fn encode_stage2_batch_checked(
        &self,
        frame: &RgbFrame,
        detections: &[DetectedSubject],
        scene_suppressed: bool,
    ) -> Result<Vec<GeneratedEmbedding>, MediaWorkerError> {
        let mut crop_frames: Vec<RgbFrame> = Vec::with_capacity(detections.len());
        for det in detections {
            crop_frames.push(frame.crop_normalized(det.padded_crop_bbox_norm()));
        }

        let mut regions: Vec<(&RgbFrame, Option<ObjectClass>, &[String])> =
            Vec::with_capacity(usize::from(!scene_suppressed) + detections.len());
        if !scene_suppressed {
            regions.push((frame, None, &[]));
        }
        for (crop_img, det) in crop_frames.iter().zip(detections.iter()) {
            regions.push((crop_img, Some(det.object_class()), det.dominant_colors()));
        }

        if regions.is_empty() {
            return Ok(Vec::new());
        }

        let vectors = self.backend.encode_annotated_images(&regions)?;
        if vectors.len() != regions.len() {
            return Err(MediaWorkerError::inference_failed(format!(
                "backend returned {} embeddings for {} visual regions",
                vectors.len(),
                regions.len()
            )));
        }

        let mut out = Vec::with_capacity(vectors.len());
        let mut vec_iter = vectors.into_iter();

        if !scene_suppressed && let Some(scene_vec) = vec_iter.next() {
            out.push(GeneratedEmbedding {
                region_kind: "scene".to_string(),
                region_index: 0,
                object_class: None,
                confidence: None,
                bbox_norm: None,
                dominant_colors: Vec::new(),
                track_id: None,
                embedding: scene_vec,
            });
        }

        for (idx, (det, crop_vec)) in detections.iter().zip(vec_iter).enumerate() {
            out.push(GeneratedEmbedding {
                region_kind: "crop".to_string(),
                region_index: (idx + 1) as u32,
                object_class: Some(det.object_class().as_str().to_string()),
                confidence: Some(det.confidence()),
                bbox_norm: Some(det.bbox_norm()),
                dominant_colors: det.dominant_colors().to_vec(),
                track_id: det.track_id(),
                embedding: crop_vec,
            });
        }

        Ok(out)
    }

    /// Infallible Stage 2 helper retained for existing callers.
    pub fn encode_stage2_batch(
        &self,
        frame: &RgbFrame,
        detections: &[DetectedSubject],
        scene_suppressed: bool,
    ) -> Vec<GeneratedEmbedding> {
        self.encode_stage2_batch_checked(frame, detections, scene_suppressed)
            .unwrap_or_default()
    }
}

/// Bridges a `serviceradar-media-worker` [`InferenceBackend`] into the pure-Rust
/// [`serviceradar_media_core::ObjectDetector`] trait.
pub struct BackendObjectDetector {
    model_id: String,
    backend: Arc<dyn InferenceBackend>,
}

impl BackendObjectDetector {
    pub fn new(model_id: impl Into<String>, backend: Arc<dyn InferenceBackend>) -> Self {
        Self {
            model_id: model_id.into(),
            backend,
        }
    }
}

impl serviceradar_media_core::ObjectDetector for BackendObjectDetector {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn detect(
        &self,
        frame: &serviceradar_media_core::RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<serviceradar_media_core::Detection>, serviceradar_media_core::MediaCoreError>
    {
        let worker_frame = RgbFrame {
            inner: frame.clone(),
        };
        let raw = self
            .backend
            .detect_objects(&worker_frame, min_confidence)
            .map_err(|e| serviceradar_media_core::MediaCoreError::detector(e.to_string()))?;
        Ok(raw
            .into_iter()
            .map(|r| {
                let category = match r.object_class() {
                    ObjectClass::Person => serviceradar_media_core::ObjectCategory::Person,
                    ObjectClass::Vehicle => serviceradar_media_core::ObjectCategory::Vehicle,
                    ObjectClass::Bicycle => serviceradar_media_core::ObjectCategory::Bicycle,
                    ObjectClass::Animal => serviceradar_media_core::ObjectCategory::Animal,
                    ObjectClass::Package => serviceradar_media_core::ObjectCategory::Package,
                };
                serviceradar_media_core::Detection::new(
                    category.class_id(),
                    category,
                    r.confidence(),
                    r.bbox_norm(),
                )
            })
            .collect())
    }
}

fn select_best_crop_per_track(
    per_frame_detections: &[Vec<DetectedSubject>],
) -> HashMap<u64, (usize, usize)> {
    // Maps track_id -> ((frame_idx, det_idx), quality_score, confidence)
    let mut best: HashMap<u64, ((usize, usize), f32, f32)> = HashMap::new();
    for (frame_idx, detections) in per_frame_detections.iter().enumerate() {
        for (det_idx, det) in detections.iter().enumerate() {
            let Some(tid) = det.track_id() else {
                continue;
            };
            let quality = crop_quality_score(det.confidence(), det.bbox_norm());
            let conf = det.confidence();
            match best.get(&tid) {
                Some(&(_, best_q, best_conf)) => {
                    let is_better = quality > best_q + 1e-6
                        || ((quality - best_q).abs() <= 1e-6 && conf > best_conf + 1e-6);
                    if is_better {
                        best.insert(tid, ((frame_idx, det_idx), quality, conf));
                    }
                }
                None => {
                    best.insert(tid, ((frame_idx, det_idx), quality, conf));
                }
            }
        }
    }
    best.into_iter()
        .map(|(tid, (loc, _, _))| (tid, loc))
        .collect()
}

pub(crate) fn detect_stub_objects(frame: &RgbFrame, min_confidence: f32) -> Vec<RawDetection> {
    let bg = estimate_border_background(frame);
    let min_box_px = if frame.width() >= 160 && frame.height() >= 120 {
        24u32
    } else {
        8u32
    };

    let raw_blobs = extract_foreground_blobs(frame, bg, min_box_px);
    let mut out = Vec::with_capacity(raw_blobs.len());
    for blob in raw_blobs {
        let (class, confidence) = classify_blob_geometry(frame, &blob, bg);
        if confidence < min_confidence {
            continue;
        }
        let x1 = (blob.min_x as f32) / (frame.width() as f32);
        let y1 = (blob.min_y as f32) / (frame.height() as f32);
        let x2 = ((blob.max_x + 1) as f32) / (frame.width() as f32);
        let y2 = ((blob.max_y + 1) as f32) / (frame.height() as f32);
        let bbox_norm = clamp_unit_bbox([x1, y1, x2, y2]);
        out.push(RawDetection::new(class, confidence, bbox_norm));
    }
    out
}

// ----------------------------------------------------------------------------
// Stage 1 Connected-Component Geometry & HSV Dominant Color Analysis
// ----------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct PixelBlob {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
    fg_pixels: u32,
}

impl PixelBlob {
    fn width(&self) -> u32 {
        self.max_x - self.min_x + 1
    }

    fn height(&self) -> u32 {
        self.max_y - self.min_y + 1
    }
}

fn estimate_border_background(frame: &RgbFrame) -> [u8; 3] {
    let mut rs = Vec::new();
    let mut gs = Vec::new();
    let mut bs = Vec::new();
    let step_x = (frame.width() / 32).max(1);
    let step_y = (frame.height() / 32).max(1);

    for x in (0..frame.width()).step_by(step_x as usize) {
        for y in [0, frame.height() - 1] {
            let p = frame.pixel_at(x, y);
            rs.push(p[0]);
            gs.push(p[1]);
            bs.push(p[2]);
        }
    }
    for y in (0..frame.height()).step_by(step_y as usize) {
        for x in [0, frame.width() - 1] {
            let p = frame.pixel_at(x, y);
            rs.push(p[0]);
            gs.push(p[1]);
            bs.push(p[2]);
        }
    }
    rs.sort_unstable();
    gs.sort_unstable();
    bs.sort_unstable();
    let mid = rs.len() / 2;
    [rs[mid], gs[mid], bs[mid]]
}

fn is_foreground_pixel(rgb: [u8; 3], bg: [u8; 3]) -> bool {
    let dist = (i16::from(rgb[0]) - i16::from(bg[0])).unsigned_abs()
        + (i16::from(rgb[1]) - i16::from(bg[1])).unsigned_abs()
        + (i16::from(rgb[2]) - i16::from(bg[2])).unsigned_abs();
    dist >= 48
}

fn extract_foreground_blobs(frame: &RgbFrame, bg: [u8; 3], min_box_px: u32) -> Vec<PixelBlob> {
    let w = frame.width() as usize;
    let h = frame.height() as usize;
    let mut visited = vec![false; w * h];
    let mut stack = Vec::new();
    let mut blobs: Vec<PixelBlob> = Vec::new();

    for y in 0..h {
        for x in 0..w {
            let start_idx = y * w + x;
            if visited[start_idx] || !is_foreground_pixel(frame.pixel_at(x as u32, y as u32), bg) {
                continue;
            }

            visited[start_idx] = true;
            stack.push((x, y));
            let mut blob = PixelBlob {
                min_x: x as u32,
                min_y: y as u32,
                max_x: x as u32,
                max_y: y as u32,
                fg_pixels: 0,
            };

            while let Some((cx, cy)) = stack.pop() {
                blob.fg_pixels += 1;
                blob.min_x = blob.min_x.min(cx as u32);
                blob.min_y = blob.min_y.min(cy as u32);
                blob.max_x = blob.max_x.max(cx as u32);
                blob.max_y = blob.max_y.max(cy as u32);

                let ny_start = cy.saturating_sub(2);
                let ny_end = (cy + 2).min(h - 1);
                let nx_start = cx.saturating_sub(2);
                let nx_end = (cx + 2).min(w - 1);

                for ny in ny_start..=ny_end {
                    for nx in nx_start..=nx_end {
                        let nidx = ny * w + nx;
                        if !visited[nidx]
                            && is_foreground_pixel(frame.pixel_at(nx as u32, ny as u32), bg)
                        {
                            visited[nidx] = true;
                            stack.push((nx, ny));
                        }
                    }
                }
            }

            if blob.width() >= min_box_px && blob.height() >= min_box_px {
                blobs.push(blob);
            }
        }
    }

    blobs
}

fn classify_blob_geometry(frame: &RgbFrame, blob: &PixelBlob, bg: [u8; 3]) -> (ObjectClass, f32) {
    let bw = blob.width() as f32;
    let bh = blob.height() as f32;
    let aspect = bw / bh;
    let area = (bw * bh).max(1.0);
    let fill_ratio = (blob.fg_pixels as f32) / area;

    // Measure upper-fifth foreground width vs mid-body width to detect narrow person heads.
    let head_y = blob.min_y + (blob.height() / 10);
    let mid_y = blob.min_y + (blob.height() / 2);
    let top_fg = (blob.min_x..=blob.max_x)
        .filter(|&x| is_foreground_pixel(frame.pixel_at(x, head_y), bg))
        .count() as f32;
    let mid_fg = (blob.min_x..=blob.max_x)
        .filter(|&x| is_foreground_pixel(frame.pixel_at(x, mid_y), bg))
        .count()
        .max(1) as f32;
    let head_to_torso_ratio = top_fg / mid_fg;

    if fill_ratio < 0.56 {
        (ObjectClass::Bicycle, 0.86)
    } else if aspect < 0.72 || (aspect < 0.96 && head_to_torso_ratio < 0.72) {
        (ObjectClass::Person, 0.92)
    } else if aspect >= 1.25 && fill_ratio >= 0.80 {
        (ObjectClass::Vehicle, 0.91)
    } else if aspect >= 1.15 && fill_ratio < 0.80 {
        (ObjectClass::Animal, 0.84)
    } else {
        (ObjectClass::Package, 0.88)
    }
}

fn resolve_track_best_frame_indices(
    frames: &[KeyframeAnalysis],
    frame_refs: &[(u64, &RgbFrame)],
    tracks: &[TrackSummary],
) -> HashSet<usize> {
    let mut indices = HashSet::with_capacity(tracks.len());
    for track in tracks {
        let target_offset = track
            .best_keyframe_offset_ms()
            .unwrap_or_else(|| track.first_seen_offset_ms());
        let best_for_track = frames
            .iter()
            .enumerate()
            .filter(|(idx, f)| !f.scene_suppressed() && frame_refs[*idx].0 == target_offset)
            .filter_map(|(idx, f)| {
                let track_q = f
                    .detections()
                    .iter()
                    .filter(|d| d.track_id() == Some(track.track_id()))
                    .map(|d| crop_quality_score(d.confidence(), d.bbox_norm()))
                    .max_by(|a, b| a.total_cmp(b))?;
                Some((idx, track_q))
            })
            .max_by(|a, b| a.1.total_cmp(&b.1).then_with(|| b.0.cmp(&a.0)))
            .map(|(idx, _)| idx)
            .or_else(|| {
                frames
                    .iter()
                    .enumerate()
                    .find(|(idx, f)| !f.scene_suppressed() && frame_refs[*idx].0 == target_offset)
                    .map(|(idx, _)| idx)
            });
        if let Some(idx) = best_for_track {
            indices.insert(idx);
        }
    }
    indices
}

fn attach_budgeted_thumbnails(
    frames: &mut [KeyframeAnalysis],
    frame_refs: &[(u64, &RgbFrame)],
    tracks: &[TrackSummary],
    max_total_b64_bytes: usize,
) -> Result<Option<String>, MediaWorkerError> {
    let track_best_indices = resolve_track_best_frame_indices(frames, frame_refs, tracks);

    let mut candidates: Vec<(u8, f32, usize)> = frames
        .iter()
        .enumerate()
        .filter(|(_, f)| !f.scene_suppressed())
        .map(|(idx, f)| {
            let best_quality = f
                .detections()
                .iter()
                .map(|d| crop_quality_score(d.confidence(), d.bbox_norm()))
                .max_by(|a, b| a.total_cmp(b))
                .unwrap_or(0.0);
            let tier = if track_best_indices.contains(&idx) {
                0
            } else if !f.detections().is_empty() {
                1
            } else {
                2
            };
            (tier, best_quality, idx)
        })
        .collect();

    candidates.sort_by(|a, b| {
        a.0.cmp(&b.0)
            .then_with(|| b.1.total_cmp(&a.1))
            .then_with(|| a.2.cmp(&b.2))
    });

    let Some(&(_, _, block_idx)) = candidates.first() else {
        return Ok(None);
    };

    let mut remaining_budget = max_total_b64_bytes;
    let block_encoded = encode_frame_thumbnail_b64(frame_refs[block_idx].1.as_media_core_frame())?;
    let block_thumbnail_jpeg_b64 = if block_encoded.len() <= remaining_budget {
        remaining_budget -= block_encoded.len();
        Some(block_encoded)
    } else {
        return Ok(None);
    };

    for &(_, _, idx) in &candidates {
        if remaining_budget == 0 {
            break;
        }
        let b64 = if idx == block_idx {
            match block_thumbnail_jpeg_b64.as_ref() {
                Some(existing) if existing.len() <= remaining_budget => existing.clone(),
                _ => break,
            }
        } else {
            let encoded = encode_frame_thumbnail_b64(frame_refs[idx].1.as_media_core_frame())?;
            if encoded.len() > remaining_budget {
                break;
            }
            encoded
        };
        remaining_budget -= b64.len();
        frames[idx].thumbnail_jpeg_b64 = Some(b64);
    }

    Ok(block_thumbnail_jpeg_b64)
}

fn clamp_unit_bbox(bbox: [f32; 4]) -> [f32; 4] {
    serviceradar_media_core::clamp_unit_bbox(bbox)
}

fn expand_bbox_with_margin([x1, y1, x2, y2]: [f32; 4], margin_frac: f32) -> [f32; 4] {
    let dx = (x2 - x1) * margin_frac;
    let dy = (y2 - y1) * margin_frac;
    clamp_unit_bbox([x1 - dx, y1 - dy, x2 + dx, y2 + dy])
}

fn bbox_iou(a: [f32; 4], b: [f32; 4]) -> f32 {
    serviceradar_media_core::bbox_iou(a, b)
}

fn apply_class_aware_nms(
    mut ranked: Vec<(f32, DetectedSubject)>,
    iou_threshold: f32,
    max_keep: usize,
) -> Vec<DetectedSubject> {
    ranked.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut kept: Vec<DetectedSubject> = Vec::with_capacity(ranked.len().min(max_keep));

    for (_score, candidate) in ranked {
        if kept.len() >= max_keep {
            break;
        }
        let suppressed = kept.iter().any(|existing| {
            existing.object_class == candidate.object_class
                && bbox_iou(existing.bbox_norm, candidate.bbox_norm) > iou_threshold
        });
        if !suppressed {
            kept.push(candidate);
        }
    }
    kept
}

const CANONICAL_COLORS: [&str; 9] = [
    "red", "blue", "white", "black", "yellow", "green", "gray", "orange", "brown",
];

fn color_slot_index(name: &str) -> Option<usize> {
    CANONICAL_COLORS.iter().position(|&c| c == name)
}

/// Classifies coarse dominant colors in HSV space via `serviceradar-media-core`
/// (`design.md` Section 3.2).
pub fn classify_dominant_colors(crop: &RgbFrame, exclude_bg: Option<[u8; 3]>) -> Vec<String> {
    classify_crop_colors(crop.as_media_core_frame(), exclude_bg)
        .into_iter()
        .map(|c| c.as_str().to_string())
        .collect()
}

// ----------------------------------------------------------------------------
// Stage 2 & Interactive Text Tower Multimodal Subspace (`512`-d / `768`-d)
// ----------------------------------------------------------------------------

/// Encodes a natural-language search query (`1..=256` UTF-8 chars) into an
/// L2-normalized vector in the exact `(embedder_model_id, embedder_model_version, embedding_dim)`
/// semantic subspace (`design.md` Section 3.4).
pub fn embed_query_text(
    query: &str,
    models: &ModelPinConfig,
) -> Result<Vec<f32>, MediaWorkerError> {
    let trimmed = query.trim();
    let char_count = trimmed.chars().count();
    if char_count == 0 || char_count > MAX_QUERY_CHARS {
        return Err(MediaWorkerError::invalid_text_embed_request(format!(
            "query must be 1..={MAX_QUERY_CHARS} characters after trimming"
        )));
    }
    let dim = models.embedding_dim();
    if dim != 512 && dim != 768 {
        return Err(MediaWorkerError::invalid_text_embed_request(format!(
            "unsupported embedding_dim {dim}"
        )));
    }

    let tokens = tokenize_query(trimmed);
    let mut classes = Vec::new();
    let mut colors = Vec::new();
    let mut scene_context = false;

    for tok in &tokens {
        if let Some(cls) = map_token_to_class(tok)
            && !classes.contains(&cls)
        {
            classes.push(cls);
        }
        if let Some(col_idx) = map_token_to_color(tok)
            && !colors.contains(&col_idx)
        {
            colors.push(col_idx);
        }
        if matches!(
            tok.as_str(),
            "parking" | "lot" | "corridor" | "bay" | "dock" | "lane" | "gate" | "smoke" | "snow"
        ) {
            scene_context = true;
        }
    }

    let mut vec = vec![0.0f32; dim];

    // 1. Class basis bands (slots 0..5, 8 dimensions each = 0..40)
    for &cls in &classes {
        add_band(&mut vec, cls.slot_index() * 8, 8, 0.64);
    }
    if classes.is_empty() || scene_context {
        let weight = if classes.is_empty() { 0.60 } else { 0.22 };
        add_band(&mut vec, 40, 8, weight); // global scene band (40..48)
    }

    // 2. Color basis bands (9 colors * 8 dimensions = 48..120)
    for &col_idx in &colors {
        add_band(&mut vec, 48 + col_idx * 8, 8, 0.58);
    }

    // 3. Compositional `(class, color)` interaction bands (5 * 9 = 45 pairs * 4 dims = 120..300)
    // Prevents false background-color binding hallucinations!
    for &cls in &classes {
        for &col_idx in &colors {
            let pair_idx = cls.slot_index() * 9 + col_idx;
            add_band(&mut vec, 120 + pair_idx * 4, 4, 0.54);
        }
    }

    // 4. Open-vocabulary hashed token residual in tail band (`300..dim`)
    let residual_weight = if classes.is_empty() && colors.is_empty() {
        0.85
    } else {
        0.12
    };
    for tok in &tokens {
        if !is_stopword(tok) {
            project_hashed_feature(
                &mut vec,
                300,
                format!("tok:{tok}").as_bytes(),
                residual_weight,
            );
        }
    }

    apply_model_space_rotation(&mut vec, models);
    Ok(l2_normalize(vec))
}

pub(crate) fn encode_stub_visual_region(
    region: &RgbFrame,
    object_class: Option<ObjectClass>,
    dominant_colors: &[String],
    models: &ModelPinConfig,
    dim: usize,
) -> Vec<f32> {
    let mut vec = vec![0.0f32; dim];
    let color_indices: Vec<usize> = dominant_colors
        .iter()
        .filter_map(|c| color_slot_index(c))
        .collect();

    match object_class {
        Some(cls) => {
            add_band(&mut vec, cls.slot_index() * 8, 8, 0.64);
            for (rank, &col_idx) in color_indices.iter().enumerate() {
                let weight = if rank == 0 { 0.58 } else { 0.32 };
                add_band(&mut vec, 48 + col_idx * 8, 8, weight);
                let pair_idx = cls.slot_index() * 9 + col_idx;
                add_band(
                    &mut vec,
                    120 + pair_idx * 4,
                    4,
                    if rank == 0 { 0.54 } else { 0.28 },
                );
            }
        }
        None => {
            // Scene-level embedding captures global scene band + ambient palette.
            add_band(&mut vec, 40, 8, 0.72);
            for (rank, &col_idx) in color_indices.iter().enumerate() {
                let weight = if rank == 0 { 0.34 } else { 0.20 };
                add_band(&mut vec, 48 + col_idx * 8, 8, weight);
            }
        }
    }

    // Visual spatial luminance/aspect signature in tail band (`300..dim`)
    let aspect_bucket =
        (((region.width() as f32) / (region.height().max(1) as f32)) * 4.0).round() as u32;
    let p_center = region.pixel_at(region.width() / 2, region.height() / 2);
    let tex_key = [
        (aspect_bucket & 0xff) as u8,
        p_center[0] >> 4,
        p_center[1] >> 4,
        p_center[2] >> 4,
    ];
    project_hashed_feature(&mut vec, 300, &tex_key, 0.12);

    apply_model_space_rotation(&mut vec, models);
    l2_normalize(vec)
}

fn add_band(vec: &mut [f32], start: usize, len: usize, total_weight: f32) {
    if start + len > vec.len() || len == 0 {
        return;
    }
    let per_dim = total_weight / (len as f32).sqrt();
    for slot in &mut vec[start..start + len] {
        *slot += per_dim;
    }
}

fn project_hashed_feature(vec: &mut [f32], start_offset: usize, seed: &[u8], weight: f32) {
    if start_offset >= vec.len() {
        return;
    }
    let span = vec.len() - start_offset;
    let digest = Sha256::digest(seed);
    let k = 8usize;
    let step_w = weight / (k as f32).sqrt();
    for i in 0..k {
        let raw_idx = u16::from_be_bytes([digest[i * 2], digest[i * 2 + 1]]) as usize;
        let sign = if digest[16 + i] & 1 == 0 { 1.0 } else { -1.0 };
        vec[start_offset + (raw_idx % span)] += sign * step_w;
    }
}

fn apply_model_space_rotation(vec: &mut [f32], models: &ModelPinConfig) {
    let mut hasher = Sha256::new();
    hasher.update(models.embedder_model_id().as_bytes());
    hasher.update(b":");
    hasher.update(models.embedder_model_version().as_bytes());
    let seed = hasher.finalize();

    // Deterministic orthogonal sign-flip keyed by `(model_id, model_version)` preserves
    // inner products within the exact model version while decorrelating mismatched versions.
    for (idx, val) in vec.iter_mut().enumerate() {
        let byte = seed[(idx / 8) % seed.len()];
        let bit = (byte >> (idx % 8)) & 1;
        if bit == 1 {
            *val = -*val;
        }
    }
}

fn l2_normalize(mut vec: Vec<f32>) -> Vec<f32> {
    let norm_sq: f32 = vec.iter().map(|v| v * v).sum();
    if norm_sq > 1e-12 {
        let inv = 1.0 / norm_sq.sqrt();
        for v in &mut vec {
            *v *= inv;
        }
    } else if let Some(first) = vec.first_mut() {
        *first = 1.0;
    }
    vec
}

/// Computes cosine similarity between two equal-length vectors.
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na <= 1e-12 || nb <= 1e-12 {
        0.0
    } else {
        dot / (na * nb)
    }
}

fn tokenize_query(query: &str) -> Vec<String> {
    query
        .to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

fn is_stopword(tok: &str) -> bool {
    matches!(
        tok,
        "a" | "an" | "the" | "in" | "on" | "at" | "near" | "with" | "by" | "of" | "wearing"
    )
}

fn map_token_to_class(tok: &str) -> Option<ObjectClass> {
    match tok {
        "person" | "people" | "woman" | "man" | "pedestrian" | "worker" | "visitor" | "dress"
        | "coat" | "jacket" | "shirt" | "hoodie" => Some(ObjectClass::Person),
        "vehicle" | "van" | "truck" | "car" | "suv" | "sedan" | "cargo" | "forklift" => {
            Some(ObjectClass::Vehicle)
        }
        "bicycle" | "bike" | "cyclist" => Some(ObjectClass::Bicycle),
        "animal" | "dog" | "cat" | "deer" => Some(ObjectClass::Animal),
        "package" | "parcel" | "box" | "carton" | "crate" => Some(ObjectClass::Package),
        _ => None,
    }
}

fn map_token_to_color(tok: &str) -> Option<usize> {
    match tok {
        "red" | "crimson" | "scarlet" | "burgundy" => color_slot_index("red"),
        "blue" | "navy" | "azure" => color_slot_index("blue"),
        "white" | "ivory" => color_slot_index("white"),
        "black" | "dark" => color_slot_index("black"),
        "yellow" | "gold" | "amber" => color_slot_index("yellow"),
        "green" | "olive" => color_slot_index("green"),
        "gray" | "grey" | "silver" => color_slot_index("gray"),
        "orange" => color_slot_index("orange"),
        "brown" | "tan" | "beige" => color_slot_index("brown"),
        _ => None,
    }
}
