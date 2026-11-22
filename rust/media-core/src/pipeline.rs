//! Cohesive end-to-end media processing stage pipeline:
//! `TwoTierFrameGate` -> `ObjectDetector` -> `extract_visual_attributes` ->
//! `MultiObjectTracker` -> `encode_jpeg_thumbnail`.

use crate::attributes::{VisualAttributes, extract_visual_attributes};
use crate::detector::{Detection, ObjectCategory, ObjectDetector};
use crate::error::MediaCoreError;
use crate::frame::RgbFrame;
use crate::frame_gate::{
    CompressedFrameGateConfig, GateAdmitReason, GateDecision, PixelMotionGateConfig,
    TwoTierFrameGate,
};
use crate::thumbnail::{EncodedThumbnail, ThumbnailConfig, encode_jpeg_thumbnail};
use crate::tracker::{
    DetectionEvent, DetectionEventKind, MultiObjectTracker, TrackSummary, TrackerConfig,
};
use std::sync::Arc;
use uuid::Uuid;

/// Configuration for [`MediaPipeline`].
#[derive(Debug, Clone)]
pub struct MediaPipelineConfig {
    pub camera_id: String,
    pub tier0_gate: CompressedFrameGateConfig,
    pub tier1_gate: PixelMotionGateConfig,
    pub tracker: TrackerConfig,
    pub thumbnail: ThumbnailConfig,
    pub min_detection_confidence: f32,
    pub attach_thumbnails: bool,
    pub emit_motion_events_when_empty: bool,
}

impl MediaPipelineConfig {
    pub fn for_camera(camera_id: impl Into<String>) -> Self {
        Self {
            camera_id: camera_id.into(),
            tier0_gate: CompressedFrameGateConfig::default(),
            tier1_gate: PixelMotionGateConfig::default(),
            tracker: TrackerConfig::default(),
            thumbnail: ThumbnailConfig::default(),
            min_detection_confidence: 0.35,
            attach_thumbnails: true,
            emit_motion_events_when_empty: true,
        }
    }
}

/// Output produced for a single processed frame.
#[derive(Debug, Clone)]
pub struct PipelineFrameOutput {
    pub timestamp_ms: u64,
    pub gate_decision: GateDecision,
    pub detections: Vec<Detection>,
    pub attributes: Vec<VisualAttributes>,
    pub assigned_track_ids: Vec<Option<u64>>,
    pub events: Vec<DetectionEvent>,
    pub thumbnail: Option<EncodedThumbnail>,
}

/// Stateful per-camera Phase 1 media pipeline combining gating, detection, HSV attributes,
/// multi-object tracking, and bounded JPEG keyframe thumbnails.
pub struct MediaPipeline {
    config: MediaPipelineConfig,
    gate: TwoTierFrameGate,
    detector: Arc<dyn ObjectDetector>,
    tracker: MultiObjectTracker,
}

impl MediaPipeline {
    pub fn new(
        config: MediaPipelineConfig,
        detector: Arc<dyn ObjectDetector>,
    ) -> Result<Self, MediaCoreError> {
        config.thumbnail.validate()?;
        let gate = TwoTierFrameGate::new(config.tier0_gate.clone(), config.tier1_gate.clone())?;
        let tracker = MultiObjectTracker::new(config.camera_id.clone(), config.tracker.clone());
        Ok(Self {
            config,
            gate,
            detector,
            tracker,
        })
    }

    pub fn detector(&self) -> &Arc<dyn ObjectDetector> {
        &self.detector
    }

    pub fn tracker(&self) -> &MultiObjectTracker {
        &self.tracker
    }

    pub fn all_track_summaries(&self) -> Vec<TrackSummary> {
        self.tracker.all_summaries()
    }

    /// Evaluates Tier 0 on compressed bytes first. Only when Tier 0 admits does it invoke
    /// `decode_rgb` and run Tier 1 -> detect -> attributes -> track -> thumbnail.
    pub fn process_compressed<F>(
        &mut self,
        timestamp_ms: u64,
        compressed_payload: &[u8],
        decode_rgb: F,
    ) -> Result<PipelineFrameOutput, MediaCoreError>
    where
        F: FnOnce() -> Result<RgbFrame, MediaCoreError>,
    {
        let tier0 = self
            .gate
            .evaluate_compressed(timestamp_ms, compressed_payload);
        if !tier0.is_admitted() {
            return Ok(PipelineFrameOutput {
                timestamp_ms,
                gate_decision: tier0,
                detections: Vec::new(),
                attributes: Vec::new(),
                assigned_track_ids: Vec::new(),
                events: Vec::new(),
                thumbnail: None,
            });
        }
        let frame = decode_rgb()?;
        self.process_rgb_frame(timestamp_ms, &frame)
    }

    /// Runs Tier 1 pixel motion gate -> YOLOX/object detector -> HSV sub-crop attributes ->
    /// `trackforge` multi-object tracker -> bounded JPEG keyframe thumbnail.
    pub fn process_rgb_frame(
        &mut self,
        timestamp_ms: u64,
        frame: &RgbFrame,
    ) -> Result<PipelineFrameOutput, MediaCoreError> {
        let motion = self.gate.evaluate_rgb(timestamp_ms, frame)?;
        if !motion.decision.is_admitted() {
            return Ok(PipelineFrameOutput {
                timestamp_ms,
                gate_decision: motion.decision,
                detections: Vec::new(),
                attributes: Vec::new(),
                assigned_track_ids: Vec::new(),
                events: Vec::new(),
                thumbnail: None,
            });
        }

        let detections = self
            .detector
            .detect(frame, self.config.min_detection_confidence)?;

        let attributes: Vec<VisualAttributes> = detections
            .iter()
            .map(|d| extract_visual_attributes(frame, d.bbox, None))
            .collect();

        let step = self.tracker.update(
            (frame.width(), frame.height()),
            timestamp_ms,
            &detections,
            Some(&attributes),
            None,
            Some(frame),
        );

        let mut events = step.events;

        // If motion triggered Tier 1 without a recognized object class, emit a MotionDetected event.
        if detections.is_empty()
            && self.config.emit_motion_events_when_empty
            && matches!(
                motion.decision,
                GateDecision::Admit {
                    reason: GateAdmitReason::PixelMotion,
                    ..
                }
            )
        {
            events.push(DetectionEvent {
                event_id: Uuid::new_v4(),
                camera_id: self.config.camera_id.clone(),
                kind: DetectionEventKind::MotionDetected,
                track_id: None,
                category: ObjectCategory::Motion,
                confidence: motion.score,
                bbox: motion.motion_bbox.unwrap_or([0.0, 0.0, 1.0, 1.0]),
                attributes: None,
                timestamp_ms,
                first_seen_ms: timestamp_ms,
                last_seen_ms: timestamp_ms,
                dwell_ms: 0,
                thumbnail: None,
            });
        }

        let needs_thumb = self.config.attach_thumbnails
            && (!events.is_empty() || !step.improved_best_keyframe_tracks.is_empty());
        let thumbnail = if needs_thumb {
            Some(encode_jpeg_thumbnail(frame, &self.config.thumbnail)?)
        } else {
            None
        };

        if let Some(ref thumb) = thumbnail {
            for ev in &mut events {
                ev.thumbnail = Some(thumb.clone());
            }
        }

        Ok(PipelineFrameOutput {
            timestamp_ms,
            gate_decision: motion.decision,
            detections,
            attributes,
            assigned_track_ids: step.assigned_track_ids,
            events,
            thumbnail,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attributes::ColorName;
    use crate::detector::SyntheticDetector;

    #[test]
    fn end_to_end_pipeline_gates_detects_attributes_tracks_and_encodes_thumbnail() {
        let mut cfg = MediaPipelineConfig::for_camera("cam-synth-gate-01");
        cfg.tracker.min_hits_to_activate = 2;
        cfg.tracker.max_lost_frames = 2;
        let detector: Arc<dyn ObjectDetector> = Arc::new(SyntheticDetector::default());
        let mut pipeline = MediaPipeline::new(cfg, detector).expect("pipeline init");

        // Frame 0: empty background establishes anchor
        let bg = RgbFrame::solid(320, 180, [190, 190, 190]);
        let r0 = pipeline.process_rgb_frame(0, &bg).unwrap();
        assert!(r0.gate_decision.is_admitted());
        assert!(r0.detections.is_empty());

        // Frame 1: identical static frame -> Tier 1 skips cleanly
        let r1 = pipeline.process_rgb_frame(1_000, &bg).unwrap();
        assert!(!r1.gate_decision.is_admitted());

        // Frame 2: person wearing red top + blue bottom enters
        let mut f2 = bg.clone();
        f2.fill_rect(60, 40, 100, 90, [220, 25, 25]);
        f2.fill_rect(60, 90, 100, 140, [25, 65, 225]);
        let r2 = pipeline.process_rgb_frame(2_000, &f2).unwrap();
        assert!(r2.gate_decision.is_admitted());
        assert_eq!(r2.detections.len(), 1);
        assert_eq!(r2.detections[0].label, ObjectCategory::Person);
        assert_eq!(r2.attributes[0].upper_body_colors, vec![ColorName::Red]);
        assert_eq!(r2.attributes[0].lower_body_colors, vec![ColorName::Blue]);
        let tid = r2.assigned_track_ids[0].expect("track id");

        // Frame 3: person moves slightly right -> promotes to Active, emits TrackEntered + JPEG thumb
        let mut f3 = bg.clone();
        f3.fill_rect(72, 40, 114, 90, [220, 25, 25]);
        f3.fill_rect(72, 90, 114, 140, [25, 65, 225]);
        let r3 = pipeline.process_rgb_frame(3_000, &f3).unwrap();
        assert!(r3.gate_decision.is_admitted());
        assert_eq!(r3.assigned_track_ids[0], Some(tid));
        assert_eq!(r3.events.len(), 1);
        assert_eq!(r3.events[0].kind, DetectionEventKind::TrackEntered);
        let thumb = r3.events[0]
            .thumbnail
            .as_ref()
            .expect("JPEG thumbnail attached to TrackEntered event");
        assert!(thumb.jpeg_bytes.starts_with(&[0xFF, 0xD8]));
        assert!(thumb.jpeg_bytes.ends_with(&[0xFF, 0xD9]));
    }
}
