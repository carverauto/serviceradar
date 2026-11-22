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

    pub fn tracker_mut(&mut self) -> &mut MultiObjectTracker {
        &mut self.tracker
    }

    pub fn all_track_summaries(&self) -> Vec<TrackSummary> {
        self.tracker.all_summaries()
    }

    pub fn take_closed_track_summaries(&mut self) -> Vec<TrackSummary> {
        self.tracker.take_closed_summaries()
    }

    /// Evaluates Tier 0 on compressed bytes first. When Tier 0 skips, `decode_rgb` is not
    /// called and `tracker.advance_time(timestamp_ms)` closes any expired `Lost` tracks.
    /// When Tier 0 admits, it invokes `decode_rgb` and runs Tier 1 -> detect -> attributes ->
    /// track -> thumbnail.
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
            let events = self.tracker.advance_time(timestamp_ms);
            return Ok(PipelineFrameOutput {
                timestamp_ms,
                gate_decision: tier0,
                detections: Vec::new(),
                attributes: Vec::new(),
                assigned_track_ids: Vec::new(),
                events,
                thumbnail: None,
            });
        }
        let frame = decode_rgb()?;
        self.process_rgb_frame(timestamp_ms, &frame)
    }

    /// Runs Tier 1 pixel motion gate -> YOLOX/object detector -> HSV sub-crop attributes ->
    /// `trackforge` multi-object tracker -> bounded JPEG keyframe thumbnail.
    ///
    /// On a Tier 1 skip, detection and thumbnail encoding are skipped while
    /// `tracker.advance_time(timestamp_ms)` closes any expired `Lost` tracks with their stored
    /// best-keyframe thumbnails.
    pub fn process_rgb_frame(
        &mut self,
        timestamp_ms: u64,
        frame: &RgbFrame,
    ) -> Result<PipelineFrameOutput, MediaCoreError> {
        let motion = self.gate.evaluate_rgb(timestamp_ms, frame)?;
        if !motion.decision.is_admitted() {
            let events = self.tracker.advance_time(timestamp_ms);
            return Ok(PipelineFrameOutput {
                timestamp_ms,
                gate_decision: motion.decision,
                detections: Vec::new(),
                attributes: Vec::new(),
                assigned_track_ids: Vec::new(),
                events,
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

        let has_current_frame_event = events
            .iter()
            .any(|ev| ev.kind != DetectionEventKind::TrackExited);
        let needs_current_frame_thumb = self.config.attach_thumbnails
            && (has_current_frame_event || !step.improved_best_keyframe_tracks.is_empty());
        let thumbnail = if needs_current_frame_thumb {
            Some(encode_jpeg_thumbnail(frame, &self.config.thumbnail)?)
        } else {
            None
        };

        if let Some(ref thumb) = thumbnail {
            for &tid in &step.improved_best_keyframe_tracks {
                self.tracker.set_best_keyframe_thumbnail(tid, thumb.clone());
            }
            for ev in &mut events {
                if ev.kind == DetectionEventKind::TrackExited {
                    if ev.thumbnail.is_none()
                        && ev
                            .track_id
                            .is_some_and(|tid| step.improved_best_keyframe_tracks.contains(&tid))
                    {
                        ev.thumbnail = Some(thumb.clone());
                    }
                } else {
                    ev.thumbnail = Some(thumb.clone());
                }
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

    #[test]
    fn exit_event_on_gate_skip_uses_stored_best_keyframe_thumbnail_without_waiting_for_heartbeat() {
        let mut cfg = MediaPipelineConfig::for_camera("cam-synth-exit-thumb-01");
        cfg.tier1_gate.max_skip_interval_ms = 60_000;
        cfg.tracker.min_hits_to_activate = 2;
        cfg.tracker.max_lost_frames = 30;
        cfg.tracker.max_lost_ms = 5_000;

        let detector: Arc<dyn ObjectDetector> = Arc::new(SyntheticDetector::default());
        let mut pipeline = MediaPipeline::new(cfg, detector).expect("pipeline init");

        let bg = RgbFrame::solid(320, 180, [190, 190, 190]);
        pipeline.process_rgb_frame(0, &bg).unwrap();

        // Frame 1: smaller person enters (New)
        let mut f1 = bg.clone();
        f1.fill_rect(60, 50, 92, 95, [220, 25, 25]);
        f1.fill_rect(60, 95, 92, 135, [25, 65, 225]);
        let r1 = pipeline.process_rgb_frame(1_000, &f1).unwrap();
        assert!(r1.gate_decision.is_admitted());
        let tid = r1.assigned_track_ids[0].expect("track id");

        // Frame 2: larger person -> Active + improved best keyframe
        let mut f2 = bg.clone();
        f2.fill_rect(54, 30, 108, 90, [220, 25, 25]);
        f2.fill_rect(54, 90, 108, 155, [25, 65, 225]);
        let r2 = pipeline.process_rgb_frame(2_000, &f2).unwrap();
        assert!(r2.gate_decision.is_admitted());
        assert_eq!(r2.assigned_track_ids[0], Some(tid));
        let best_thumb = r2
            .thumbnail
            .as_ref()
            .expect("best keyframe thumbnail encoded on improvement")
            .clone();

        // Frame 3: person leaves -> admitted empty background, track becomes Lost
        let r3 = pipeline.process_rgb_frame(3_000, &bg).unwrap();
        assert!(r3.gate_decision.is_admitted());
        assert!(r3.detections.is_empty());
        let empty_thumb = r3
            .thumbnail
            .as_ref()
            .expect("motion thumbnail encoded for departure")
            .clone();
        assert_ne!(best_thumb.sha256_hex, empty_thumb.sha256_hex);

        // Frame 4 (t=4s): static empty scene -> skipped, not yet expired
        let r4 = pipeline.process_rgb_frame(4_000, &bg).unwrap();
        assert!(!r4.gate_decision.is_admitted());
        assert!(r4.events.is_empty());

        // Frame 5 (t=7s, 5s after last_seen=2s, well before 60s heartbeat):
        // skipped by Tier 1, yet TrackExited fires promptly with the best-keyframe thumbnail!
        let r5 = pipeline.process_rgb_frame(7_000, &bg).unwrap();
        assert!(!r5.gate_decision.is_admitted());
        assert!(r5.thumbnail.is_none());
        assert_eq!(r5.events.len(), 1);
        assert_eq!(r5.events[0].kind, DetectionEventKind::TrackExited);
        assert_eq!(r5.events[0].track_id, Some(tid));
        assert_eq!(r5.events[0].timestamp_ms, 7_000);
        let exit_thumb = r5.events[0]
            .thumbnail
            .as_ref()
            .expect("TrackExited must carry stored best-keyframe thumbnail");
        assert_eq!(exit_thumb.sha256_hex, best_thumb.sha256_hex);
        assert_ne!(exit_thumb.sha256_hex, empty_thumb.sha256_hex);
    }

    #[test]
    fn exit_event_on_admitted_frame_preserves_best_keyframe_thumbnail_alongside_motion() {
        let mut cfg = MediaPipelineConfig::for_camera("cam-synth-exit-admit-01");
        cfg.tracker.min_hits_to_activate = 1;
        cfg.tracker.max_lost_frames = 1;
        cfg.tracker.max_lost_ms = 30_000;

        let detector: Arc<dyn ObjectDetector> = Arc::new(SyntheticDetector::default());
        let mut pipeline = MediaPipeline::new(cfg, detector).expect("pipeline init");

        let bg = RgbFrame::solid(320, 180, [190, 190, 190]);
        pipeline.process_rgb_frame(0, &bg).unwrap();

        let mut f1 = bg.clone();
        f1.fill_rect(60, 35, 112, 92, [220, 25, 25]);
        f1.fill_rect(60, 92, 112, 150, [25, 65, 225]);
        let r1 = pipeline.process_rgb_frame(1_000, &f1).unwrap();
        let best_thumb = r1.thumbnail.as_ref().expect("best keyframe thumb").clone();

        // Departure frame is admitted with PixelMotion, emitting both TrackExited and MotionDetected.
        let r2 = pipeline.process_rgb_frame(2_000, &bg).unwrap();
        let current_thumb = r2.thumbnail.as_ref().expect("current frame thumb").clone();
        assert_ne!(best_thumb.sha256_hex, current_thumb.sha256_hex);

        let exit_ev = r2
            .events
            .iter()
            .find(|e| e.kind == DetectionEventKind::TrackExited)
            .expect("TrackExited emitted");
        let motion_ev = r2
            .events
            .iter()
            .find(|e| e.kind == DetectionEventKind::MotionDetected)
            .expect("MotionDetected emitted");

        assert_eq!(
            exit_ev.thumbnail.as_ref().unwrap().sha256_hex,
            best_thumb.sha256_hex
        );
        assert_eq!(
            motion_ev.thumbnail.as_ref().unwrap().sha256_hex,
            current_thumb.sha256_hex
        );
    }

    #[test]
    fn process_compressed_tier0_skip_advances_tracker_without_decoding() {
        let mut cfg = MediaPipelineConfig::for_camera("cam-synth-tier0-skip-01");
        cfg.tier0_gate.max_skip_interval_ms = 60_000;
        cfg.tracker.min_hits_to_activate = 1;
        cfg.tracker.max_lost_frames = 30;
        cfg.tracker.max_lost_ms = 5_000;

        let detector: Arc<dyn ObjectDetector> = Arc::new(SyntheticDetector::default());
        let mut pipeline = MediaPipeline::new(cfg, detector).expect("pipeline init");

        let bg = RgbFrame::solid(320, 180, [190, 190, 190]);
        let mut person_frame = bg.clone();
        person_frame.fill_rect(60, 35, 112, 92, [220, 25, 25]);
        person_frame.fill_rect(60, 92, 112, 150, [25, 65, 225]);

        let payload_present = vec![0xAAu8; 2_000];
        let r0 = pipeline
            .process_compressed(1_000, &payload_present, || Ok(person_frame.clone()))
            .unwrap();
        assert!(r0.gate_decision.is_admitted());
        let tid = r0.assigned_track_ids[0].expect("track id");
        let best_thumb = r0.thumbnail.as_ref().expect("best keyframe thumb").clone();

        // Departure frame with >8% compressed size delta admits through Tier 0 and Tier 1,
        // marking the track Lost before subsequent identical empty frames skip at Tier 0.
        let payload_empty = vec![0xBBu8; 3_000];
        let r1 = pipeline
            .process_compressed(2_000, &payload_empty, || Ok(bg.clone()))
            .unwrap();
        assert!(r1.gate_decision.is_admitted());
        assert!(r1.detections.is_empty());
        assert_eq!(
            pipeline.tracker().live_summaries()[0].state,
            crate::TrackState::Lost
        );

        // Identical empty compressed payload 5s after last_seen (well before 60s Tier 0 heartbeat):
        // must skip decode_rgb and still emit TrackExited with best_thumb.
        let r2 = pipeline
            .process_compressed(6_000, &payload_empty, || {
                panic!("decode_rgb must not be called on Tier 0 skip")
            })
            .unwrap();
        assert!(!r2.gate_decision.is_admitted());
        assert_eq!(r2.events.len(), 1);
        assert_eq!(r2.events[0].kind, DetectionEventKind::TrackExited);
        assert_eq!(r2.events[0].track_id, Some(tid));
        assert_eq!(
            r2.events[0].thumbnail.as_ref().unwrap().sha256_hex,
            best_thumb.sha256_hex
        );
    }

    #[test]
    fn stationary_active_track_survives_gate_skips_past_max_lost_ms_and_keeps_id_on_heartbeat() {
        let mut cfg = MediaPipelineConfig::for_camera("cam-synth-stationary-01");
        cfg.tier1_gate.max_skip_interval_ms = 20_000;
        cfg.tracker.min_hits_to_activate = 1;
        cfg.tracker.max_lost_frames = 30;
        cfg.tracker.max_lost_ms = 5_000;

        let detector: Arc<dyn ObjectDetector> = Arc::new(SyntheticDetector::default());
        let mut pipeline = MediaPipeline::new(cfg, detector).expect("pipeline init");

        let bg = RgbFrame::solid(320, 180, [190, 190, 190]);
        pipeline.process_rgb_frame(0, &bg).unwrap();

        let mut stationary = bg.clone();
        stationary.fill_rect(60, 35, 112, 92, [220, 25, 25]);
        stationary.fill_rect(60, 92, 112, 150, [25, 65, 225]);
        let r1 = pipeline.process_rgb_frame(1_000, &stationary).unwrap();
        assert!(r1.gate_decision.is_admitted());
        let tid = r1.assigned_track_ids[0].expect("track id");
        assert_eq!(r1.events.len(), 1);
        assert_eq!(r1.events[0].kind, DetectionEventKind::TrackEntered);

        // Identical static scene well past max_lost_ms (5s): Tier 1 skips and track stays Active.
        let r2 = pipeline.process_rgb_frame(10_000, &stationary).unwrap();
        assert!(!r2.gate_decision.is_admitted());
        assert!(r2.events.is_empty());
        assert_eq!(pipeline.tracker().live_summaries().len(), 1);
        assert_eq!(pipeline.tracker().live_summaries()[0].track_id, tid);
        assert_eq!(
            pipeline.tracker().live_summaries()[0].state,
            crate::TrackState::Active
        );
        assert!(pipeline.tracker().closed_summaries().is_empty());

        // Heartbeat at t=21s re-detects the stationary object under the same track_id with no churn.
        let r3 = pipeline.process_rgb_frame(21_000, &stationary).unwrap();
        assert!(r3.gate_decision.is_admitted());
        assert_eq!(r3.assigned_track_ids[0], Some(tid));
        assert!(r3.events.is_empty());
        assert_eq!(pipeline.tracker().live_summaries().len(), 1);
        assert_eq!(pipeline.tracker().live_summaries()[0].track_id, tid);
        assert_eq!(pipeline.tracker().live_summaries()[0].dwell_ms, 20_000);
        assert!(pipeline.tracker().closed_summaries().is_empty());
    }
}
