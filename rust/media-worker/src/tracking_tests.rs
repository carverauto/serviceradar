//! Synthetic multi-frame tracking, appearance Re-ID, best-crop deduplication,
//! and config/probe exposure tests for `trackforge` integration.

use crate::backend::{InferenceBackend, InferenceBackendInfo, InferenceBackendKind, RawDetection};
use crate::capability::{
    GpuEnvironmentObservation, GpuEnvironmentProbe, verify_startup_capabilities_with_backend,
};
use crate::config::{CliArgs, ModelPinConfig, WorkerConfig};
use crate::errors::{CapabilityError, MediaWorkerError};
use crate::http_server::{ReadinessState, serve_http_probes};
use crate::metrics::WorkerMetrics;
use crate::tracking::TrackerMode;
use crate::vision::{ClipKeyframe, ObjectClass, RgbFrame, VisionPipeline};
use crate::worker::{DetectionPayload, EmbeddingPayload, VisualIndexResultEnvelope};
use clap::Parser;
use std::collections::HashSet;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

struct FixedGpuProbe;

impl GpuEnvironmentProbe for FixedGpuProbe {
    fn observe(
        &self,
        _config: &WorkerConfig,
    ) -> Result<GpuEnvironmentObservation, CapabilityError> {
        Ok(GpuEnvironmentObservation::no_gpu())
    }
}

/// Deterministic scripted backend for multi-frame tracking & deduplication tests.
///
/// Each frame's first pixel `r` channel indexes into `scripted_frames`, so tests can
/// feed exact synthetic boxes, confidences, and L2-normalized embeddings while counting
/// how many Stage 2 `:crop` and `:scene` embeddings are actually requested.
type ScriptedDetection = (ObjectClass, f32, [f32; 4], Vec<f32>);

struct ScriptedTrackingBackend {
    dim: usize,
    scripted_frames: Vec<Vec<ScriptedDetection>>,
    scene_embed_calls: AtomicUsize,
    crop_embed_calls: AtomicUsize,
}

impl ScriptedTrackingBackend {
    fn new(dim: usize, scripted_frames: Vec<Vec<ScriptedDetection>>) -> Self {
        Self {
            dim,
            scripted_frames,
            scene_embed_calls: AtomicUsize::new(0),
            crop_embed_calls: AtomicUsize::new(0),
        }
    }

    fn scene_calls(&self) -> usize {
        self.scene_embed_calls.load(Ordering::SeqCst)
    }

    fn crop_calls(&self) -> usize {
        self.crop_embed_calls.load(Ordering::SeqCst)
    }
}

impl InferenceBackend for ScriptedTrackingBackend {
    fn info(&self) -> InferenceBackendInfo {
        InferenceBackendInfo::new(InferenceBackendKind::Stub, "cpu", self.dim, "test", true)
    }

    fn detect_objects(
        &self,
        frame: &RgbFrame,
        _min_confidence: f32,
    ) -> Result<Vec<RawDetection>, MediaWorkerError> {
        let frame_idx = usize::from(frame.pixel_at(0, 0)[0]);
        let entries = self
            .scripted_frames
            .get(frame_idx)
            .cloned()
            .unwrap_or_default();
        Ok(entries
            .into_iter()
            .map(|(cls, conf, bbox, _)| RawDetection::new(cls, conf, bbox))
            .collect())
    }

    fn encode_annotated_images(
        &self,
        regions: &[(&RgbFrame, Option<ObjectClass>, &[String])],
    ) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
        let mut out = Vec::with_capacity(regions.len());
        let mut crop_cursor = 0usize;
        for (img, cls, _colors) in regions {
            if cls.is_none() {
                self.scene_embed_calls.fetch_add(1, Ordering::SeqCst);
                let mut v = vec![0.0_f32; self.dim];
                v[0] = 1.0;
                out.push(v);
            } else {
                self.crop_embed_calls.fetch_add(1, Ordering::SeqCst);
                let frame_idx = usize::from(img.pixel_at(0, 0)[0]);
                let vec_opt = self
                    .scripted_frames
                    .get(frame_idx)
                    .and_then(|entries| entries.get(crop_cursor))
                    .map(|(_, _, _, emb)| emb.clone());
                crop_cursor += 1;
                out.push(vec_opt.unwrap_or_else(|| {
                    let mut v = vec![0.0_f32; self.dim];
                    v[1 % self.dim] = 1.0;
                    v
                }));
            }
        }
        Ok(out)
    }

    fn encode_images(&self, images: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
        let mut out = Vec::with_capacity(images.len());
        for _ in images {
            let mut v = vec![0.0_f32; self.dim];
            v[0] = 1.0;
            out.push(v);
        }
        Ok(out)
    }

    fn encode_text(&self, _text: &str) -> Result<Vec<f32>, MediaWorkerError> {
        let mut v = vec![0.0_f32; self.dim];
        v[0] = 1.0;
        Ok(v)
    }
}

fn tagged_frame(tag: u8) -> RgbFrame {
    RgbFrame::solid(160, 120, [tag, 30, 40])
}

fn unit_basis_vec(dim: usize, axis: usize) -> Vec<f32> {
    let mut v = vec![0.0_f32; dim];
    v[axis % dim] = 1.0;
    v
}

#[test]
fn bytetrack_maintains_stable_track_ids_across_moving_person_and_vehicle() {
    let dim = 16;
    let person_emb = unit_basis_vec(dim, 1);
    let vehicle_emb = unit_basis_vec(dim, 2);

    // 6 keyframes (1000ms apart): person walks right, vehicle drives left.
    let mut scripted = Vec::new();
    for step in 0..6u8 {
        let s = f32::from(step);
        let person_x1 = 0.08 + s * 0.04;
        let person_box = [person_x1, 0.25, person_x1 + 0.14, 0.75];
        let vehicle_x1 = 0.68 - s * 0.03;
        let vehicle_box = [vehicle_x1, 0.40, vehicle_x1 + 0.22, 0.68];

        scripted.push(vec![
            (ObjectClass::Person, 0.88, person_box, person_emb.clone()),
            (ObjectClass::Vehicle, 0.91, vehicle_box, vehicle_emb.clone()),
        ]);
    }

    let backend = Arc::new(ScriptedTrackingBackend::new(dim, scripted));
    let pipeline = VisionPipeline::with_backend(
        ModelPinConfig::new("det", "1", "emb", "1", dim),
        true,
        Arc::clone(&backend) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::ByteTrack, true);

    let frames: Vec<RgbFrame> = (0..6u8).map(tagged_frame).collect();
    let keyframes: Vec<ClipKeyframe<'_>> = frames
        .iter()
        .enumerate()
        .map(|(i, f)| ClipKeyframe::new((i as u64) * 1_000, f))
        .collect();

    let clip = pipeline
        .process_clip_keyframes(&keyframes)
        .expect("process clip keyframes");

    assert_eq!(clip.frames().len(), 6);
    assert_eq!(clip.tracks().len(), 2);

    let mut person_ids = HashSet::new();
    let mut vehicle_ids = HashSet::new();
    for frame in clip.frames() {
        assert_eq!(frame.detections().len(), 2);
        for det in frame.detections() {
            let tid = det.track_id().expect("assigned track_id");
            match det.object_class() {
                ObjectClass::Person => {
                    person_ids.insert(tid);
                }
                ObjectClass::Vehicle => {
                    vehicle_ids.insert(tid);
                }
                other => panic!("unexpected class {other:?}"),
            }
        }
    }

    assert_eq!(
        person_ids.len(),
        1,
        "person should keep one stable track_id"
    );
    assert_eq!(
        vehicle_ids.len(),
        1,
        "vehicle should keep one stable track_id"
    );
    assert_ne!(person_ids, vehicle_ids);

    for summary in clip.tracks() {
        assert_eq!(summary.first_seen_offset_ms(), 0);
        assert_eq!(summary.last_seen_offset_ms(), 5_000);
        assert_eq!(summary.dwell_ms(), 5_000);
        assert_eq!(summary.frame_count(), 6);
    }

    // Stateless across clips: a second clip starts fresh at track_id = 1.
    let clip2 = pipeline
        .process_clip_keyframes(&keyframes)
        .expect("second clip");
    assert_eq!(clip2.tracks()[0].track_id(), 1);
}

#[test]
fn best_crop_deduplication_reduces_stage2_crop_calls_and_selects_highest_quality_crop() {
    let dim = 16;
    let person_emb = unit_basis_vec(dim, 3);

    // 5 keyframes of the same moving person; frame 3 (offset 3000ms) has largest area * confidence.
    let specs: [(f32, [f32; 4]); 5] = [
        (0.70, [0.10, 0.25, 0.22, 0.65]), // area = 0.048, q = 0.0336
        (0.80, [0.12, 0.25, 0.25, 0.67]), // area = 0.0546, q = 0.04368
        (0.85, [0.14, 0.24, 0.28, 0.68]), // area = 0.0616, q = 0.05236
        (0.96, [0.16, 0.20, 0.34, 0.76]), // area = 0.1008, q = 0.096768  <-- BEST
        (0.82, [0.18, 0.25, 0.31, 0.69]), // area = 0.0572, q = 0.046904
    ];

    let scripted: Vec<_> = specs
        .iter()
        .map(|&(conf, bbox)| vec![(ObjectClass::Person, conf, bbox, person_emb.clone())])
        .collect();

    // 1. With dedup enabled (default): only 1 crop embedding call instead of 5.
    let backend_dedup = Arc::new(ScriptedTrackingBackend::new(dim, scripted.clone()));
    let pipeline_dedup = VisionPipeline::with_backend(
        ModelPinConfig::new("det", "1", "emb", "1", dim),
        true,
        Arc::clone(&backend_dedup) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::ByteTrack, true);

    let frames: Vec<RgbFrame> = (0..5u8).map(tagged_frame).collect();
    let keyframes: Vec<ClipKeyframe<'_>> = frames
        .iter()
        .enumerate()
        .map(|(i, f)| ClipKeyframe::new((i as u64) * 1_000, f))
        .collect();

    let clip_dedup = pipeline_dedup
        .process_clip_keyframes(&keyframes)
        .expect("dedup clip");

    assert_eq!(
        backend_dedup.scene_calls(),
        5,
        "all 5 scene frames embedded"
    );
    assert_eq!(
        backend_dedup.crop_calls(),
        1,
        "best-crop deduplication must reduce 5 frame crops to 1 Stage 2 crop embedding call"
    );

    let crop_frames: Vec<usize> = clip_dedup
        .frames()
        .iter()
        .enumerate()
        .filter(|(_, f)| f.embeddings().iter().any(|e| e.region_kind() == "crop"))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        crop_frames,
        vec![3],
        "frame 3 had the highest confidence * area crop"
    );

    assert_eq!(clip_dedup.tracks().len(), 1);
    let summary = &clip_dedup.tracks()[0];
    assert_eq!(summary.object_class(), ObjectClass::Person);
    assert_eq!(summary.first_seen_offset_ms(), 0);
    assert_eq!(summary.last_seen_offset_ms(), 4_000);
    assert_eq!(summary.dwell_ms(), 4_000);
    assert_eq!(summary.frame_count(), 5);
    assert!((summary.peak_confidence() - 0.96).abs() < 1e-5);

    // 2. With dedup disabled: all 5 crops are embedded.
    let backend_full = Arc::new(ScriptedTrackingBackend::new(dim, scripted));
    let pipeline_full = VisionPipeline::with_backend(
        ModelPinConfig::new("det", "1", "emb", "1", dim),
        true,
        Arc::clone(&backend_full) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::ByteTrack, false);

    let clip_full = pipeline_full
        .process_clip_keyframes(&keyframes)
        .expect("non-dedup clip");
    assert_eq!(backend_full.crop_calls(), 5);
    assert_eq!(clip_full.tracks().len(), 1);
    assert_eq!(clip_full.tracks()[0].frame_count(), 5);
}

#[test]
fn botsort_and_deep_ocsort_link_tracks_with_appearance_embeddings() {
    let dim = 16;
    let emb_a = unit_basis_vec(dim, 4);

    // 5 frames of a moving person with consistent L2-normalized Re-ID embedding.
    let mut scripted_botsort = Vec::new();
    for step in 0..5u8 {
        let s = f32::from(step);
        let x1 = 0.15 + s * 0.05;
        scripted_botsort.push(vec![(
            ObjectClass::Person,
            0.90,
            [x1, 0.20, x1 + 0.18, 0.72],
            emb_a.clone(),
        )]);
    }

    let frames: Vec<RgbFrame> = (0..5u8).map(tagged_frame).collect();
    let keyframes: Vec<ClipKeyframe<'_>> = frames
        .iter()
        .enumerate()
        .map(|(i, f)| ClipKeyframe::new((i as u64) * 500, f))
        .collect();

    // Test BoT-SORT with best-crop dedup enabled.
    let backend_bs = Arc::new(ScriptedTrackingBackend::new(dim, scripted_botsort));
    let pipeline_bs = VisionPipeline::with_backend(
        ModelPinConfig::new("det", "1", "emb", "1", dim),
        true,
        Arc::clone(&backend_bs) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::BotSort, true);

    let clip_bs = pipeline_bs
        .process_clip_keyframes(&keyframes)
        .expect("botsort clip");
    assert_eq!(clip_bs.tracks().len(), 1);
    assert_eq!(clip_bs.tracks()[0].frame_count(), 5);
    assert_eq!(clip_bs.tracks()[0].dwell_ms(), 2_000);
    let emitted_crops_bs: usize = clip_bs
        .frames()
        .iter()
        .flat_map(|f| f.embeddings().iter())
        .filter(|e| e.region_kind() == "crop")
        .count();
    assert_eq!(
        emitted_crops_bs, 1,
        "botsort with dedup emits 1 best crop per track"
    );

    // Test Deep OC-SORT linking across a non-overlapping spatial jump via appearance Re-ID.
    let scripted_doc = vec![
        vec![(
            ObjectClass::Vehicle,
            0.92,
            [0.05, 0.30, 0.25, 0.60],
            emb_a.clone(),
        )],
        vec![(
            ObjectClass::Vehicle,
            0.93,
            [0.10, 0.30, 0.30, 0.60],
            emb_a.clone(),
        )],
        // Spatial jump (zero IoU with previous box), identical appearance embedding.
        vec![(
            ObjectClass::Vehicle,
            0.94,
            [0.55, 0.30, 0.75, 0.60],
            emb_a.clone(),
        )],
        vec![(
            ObjectClass::Vehicle,
            0.95,
            [0.60, 0.30, 0.80, 0.60],
            emb_a.clone(),
        )],
    ];

    let frames_doc: Vec<RgbFrame> = (0..4u8).map(tagged_frame).collect();
    let keyframes_doc: Vec<ClipKeyframe<'_>> = frames_doc
        .iter()
        .enumerate()
        .map(|(i, f)| ClipKeyframe::new((i as u64) * 1_000, f))
        .collect();

    let backend_doc = Arc::new(ScriptedTrackingBackend::new(dim, scripted_doc));
    let pipeline_doc = VisionPipeline::with_backend(
        ModelPinConfig::new("det", "1", "emb", "1", dim),
        true,
        Arc::clone(&backend_doc) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::DeepOcSort, true);

    let clip_doc = pipeline_doc
        .process_clip_keyframes(&keyframes_doc)
        .expect("deep_ocsort clip");

    assert_eq!(
        clip_doc.tracks().len(),
        1,
        "Deep OC-SORT should link the track across a zero-IoU jump using matching appearance embeddings"
    );
    assert_eq!(clip_doc.tracks()[0].frame_count(), 4);
    assert_eq!(clip_doc.tracks()[0].dwell_ms(), 3_000);
}

#[test]
fn tracker_mode_off_preserves_untracked_per_frame_behavior_and_wire_compat() {
    let dim = 16;
    let emb = unit_basis_vec(dim, 5);
    let scripted = vec![
        vec![(
            ObjectClass::Person,
            0.90,
            [0.20, 0.20, 0.40, 0.70],
            emb.clone(),
        )],
        vec![(
            ObjectClass::Person,
            0.91,
            [0.21, 0.20, 0.41, 0.70],
            emb.clone(),
        )],
        vec![(ObjectClass::Person, 0.92, [0.22, 0.20, 0.42, 0.70], emb)],
    ];

    let backend = Arc::new(ScriptedTrackingBackend::new(dim, scripted));
    let pipeline = VisionPipeline::with_backend(
        ModelPinConfig::new("det", "1", "emb", "1", dim),
        true,
        Arc::clone(&backend) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::Off, true);

    let frames: Vec<RgbFrame> = (0..3u8).map(tagged_frame).collect();
    let keyframes: Vec<ClipKeyframe<'_>> = frames
        .iter()
        .enumerate()
        .map(|(i, f)| ClipKeyframe::new((i as u64) * 1_000, f))
        .collect();

    let clip = pipeline
        .process_clip_keyframes(&keyframes)
        .expect("off clip");

    assert!(clip.tracks().is_empty());
    assert_eq!(
        backend.crop_calls(),
        3,
        "untracked mode embeds every frame's crops"
    );
    for frame in clip.frames() {
        assert_eq!(frame.detections().len(), 1);
        assert_eq!(frame.detections()[0].track_id(), None);
        assert_eq!(frame.embeddings().len(), 2);
        assert!(frame.embeddings().iter().all(|e| e.track_id().is_none()));
    }

    // Legacy JSON without `track_id` or `tracks` must deserialize cleanly.
    let legacy_json = serde_json::json!({
        "schema": "media.results.visual_index.v1",
        "schema_version": 1,
        "job_id": "job-legacy-1",
        "catalog_entry_id": "cat-1",
        "descriptor_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "detector_model_id": "rtdetr-r18",
        "detector_model_version": "2026.1",
        "embedder_model_id": "siglip-b16-384",
        "embedder_model_version": "2026.1",
        "model_id": "siglip-b16-384",
        "model_version": "2026.1",
        "embedding_dim": 4,
        "frames": [{
            "fragment_sequence": 1,
            "media_pts_ns": 1000,
            "scene_suppressed": false,
            "detections": [{
                "object_class": "person",
                "confidence": 0.9,
                "bbox": [0.1, 0.2, 0.3, 0.8],
                "dominant_colors": ["blue"]
            }],
            "embeddings": [{
                "region_kind": "crop",
                "region_index": 1,
                "object_class": "person",
                "confidence": 0.9,
                "bbox": [0.1, 0.2, 0.3, 0.8],
                "dominant_colors": ["blue"],
                "embedding": [1.0, 0.0, 0.0, 0.0]
            }]
        }]
    });

    let parsed: VisualIndexResultEnvelope =
        serde_json::from_value(legacy_json).expect("legacy envelope deserializes");
    assert!(parsed.tracks().is_empty());
    let det: &DetectionPayload = &parsed.frames()[0].detections()[0];
    let emb_p: &EmbeddingPayload = &parsed.frames()[0].embeddings()[0];
    assert_eq!(det.track_id(), None);
    assert_eq!(emb_p.track_id(), None);

    // Re-serializing omits empty `tracks`, `None` `track_id`, and `None` thumbnails.
    let reserialized = serde_json::to_value(&parsed).expect("reserialize");
    assert!(reserialized.get("tracks").is_none());
    assert!(reserialized.get("block_thumbnail_jpeg_b64").is_none());
    assert!(
        reserialized["frames"][0]
            .get("thumbnail_jpeg_b64")
            .is_none()
    );
    assert!(
        reserialized["frames"][0]["detections"][0]
            .get("track_id")
            .is_none()
    );
    assert!(
        reserialized["frames"][0]["embeddings"][0]
            .get("track_id")
            .is_none()
    );
}

#[tokio::test]
async fn config_and_http_probes_expose_tracker_mode_and_dedup_setting() {
    let args = CliArgs::try_parse_from([
        "serviceradar-media-worker",
        "--execution-provider",
        "cpu_explicit",
        "--tracker",
        "botsort",
        "--dedup-track-crops",
        "false",
    ])
    .expect("parse cli args");
    let cfg = args.into_worker_config().expect("into worker config");
    assert_eq!(cfg.tracker_mode(), TrackerMode::BotSort);
    assert!(!cfg.dedup_track_crops());

    // Invalid tracker mode fails closed.
    let bad_args = CliArgs::try_parse_from([
        "serviceradar-media-worker",
        "--execution-provider",
        "cpu_explicit",
        "--tracker",
        "unknown_tracker",
    ])
    .expect("parse bad tracker flag");
    assert!(bad_args.into_worker_config().is_err());

    // Verify /healthz and /readyz expose tracker and dedup_track_crops.
    let config = WorkerConfig::cpu_explicit_default()
        .with_backend_kind(InferenceBackendKind::Stub)
        .with_tracker_mode(TrackerMode::DeepOcSort)
        .with_dedup_track_crops(true);
    let backend: Arc<dyn InferenceBackend> = Arc::new(
        crate::backend::DeterministicStubBackend::new(config.models().clone()),
    );
    let manifest = verify_startup_capabilities_with_backend(&config, &FixedGpuProbe, backend)
        .expect("startup capability verification");
    assert_eq!(manifest.tracker(), TrackerMode::DeepOcSort);
    assert!(manifest.dedup_track_crops());

    let metrics = Arc::new(WorkerMetrics::new());
    let readiness = ReadinessState::ready(manifest, metrics);
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let addr = serve_http_probes(
        SocketAddr::from(([127, 0, 0, 1], 0)),
        readiness,
        shutdown_rx,
    )
    .await
    .expect("bind probes");

    let healthz_url = format!("http://{addr}/healthz");
    let healthz: serde_json::Value = tokio::task::spawn_blocking(move || {
        ureq::get(&healthz_url)
            .call()
            .expect("GET /healthz")
            .body_mut()
            .read_json()
            .expect("healthz json")
    })
    .await
    .expect("join healthz");
    assert_eq!(healthz["tracker"], "deep_ocsort");
    assert_eq!(healthz["dedup_track_crops"], true);

    let readyz_url = format!("http://{addr}/readyz");
    let readyz: serde_json::Value = tokio::task::spawn_blocking(move || {
        ureq::get(&readyz_url)
            .call()
            .expect("GET /readyz")
            .body_mut()
            .read_json()
            .expect("readyz json")
    })
    .await
    .expect("join readyz");
    assert_eq!(readyz["tracker"], "deep_ocsort");
    assert_eq!(readyz["dedup_track_crops"], true);

    let _ = shutdown_tx.send(true);
}

#[test]
fn vision_pipeline_bridges_into_media_core_stage_pipeline() {
    let config = WorkerConfig::cpu_explicit_default().with_backend_kind(InferenceBackendKind::Stub);
    let backend: Arc<dyn InferenceBackend> = Arc::new(
        crate::backend::DeterministicStubBackend::new(config.models().clone()),
    );
    let vision = VisionPipeline::with_backend(config.models().clone(), true, backend);

    let mut mc_cfg = crate::MediaPipelineConfig::for_camera("cam-synth-worker-01");
    mc_cfg.tracker.min_hits_to_activate = 1;
    mc_cfg.tracker.max_lost_frames = 30;
    mc_cfg.tracker.max_lost_ms = 5_000;
    let mut stage_pipeline = vision
        .build_media_core_pipeline(mc_cfg)
        .expect("build media-core stage pipeline");

    let bg = RgbFrame::solid(320, 180, [190, 190, 190])
        .to_media_core_frame()
        .expect("convert bg frame");
    let r0 = stage_pipeline
        .process_rgb_frame(0, &bg)
        .expect("process anchor");
    assert!(r0.gate_decision.is_admitted());

    let r1 = stage_pipeline
        .process_rgb_frame(1_000, &bg)
        .expect("process static");
    assert!(!r1.gate_decision.is_admitted());

    let mut moved = bg.clone();
    moved.fill_rect(60, 40, 100, 90, [220, 25, 25]);
    moved.fill_rect(60, 90, 100, 140, [25, 65, 225]);
    let r2 = stage_pipeline
        .process_rgb_frame(2_000, &moved)
        .expect("process moving person");
    assert!(r2.gate_decision.is_admitted());
    assert!(!r2.detections.is_empty());
    let tid = r2.assigned_track_ids[0].expect("track id assigned");
    assert_eq!(
        r2.attributes[0].upper_body_colors,
        vec![crate::ColorName::Red]
    );
    assert_eq!(
        r2.attributes[0].lower_body_colors,
        vec![crate::ColorName::Blue]
    );
    let best_thumb = r2
        .thumbnail
        .as_ref()
        .expect("best-keyframe JPEG thumbnail")
        .clone();
    assert!(best_thumb.jpeg_bytes.starts_with(&[0xFF, 0xD8]));
    assert!(best_thumb.jpeg_bytes.ends_with(&[0xFF, 0xD9]));
    assert!(
        r2.events
            .iter()
            .any(|e| e.kind == crate::DetectionEventKind::TrackEntered && e.track_id == Some(tid))
    );

    // Person departs -> admitted empty scene marks track Lost
    let r3 = stage_pipeline
        .process_rgb_frame(3_000, &bg)
        .expect("process departure");
    assert!(r3.gate_decision.is_admitted());
    assert!(r3.detections.is_empty());

    // Static empty scene past max_lost_ms -> skipped by Tier 1 yet TrackExited fires with best_thumb
    let r4 = stage_pipeline
        .process_rgb_frame(8_000, &bg)
        .expect("process skipped post-departure");
    assert!(!r4.gate_decision.is_admitted());
    assert_eq!(r4.events.len(), 1);
    assert_eq!(r4.events[0].kind, crate::DetectionEventKind::TrackExited);
    assert_eq!(r4.events[0].track_id, Some(tid));
    assert_eq!(
        r4.events[0].thumbnail.as_ref().unwrap().sha256_hex,
        best_thumb.sha256_hex
    );
    let closed = stage_pipeline.take_closed_track_summaries();
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0].track_id, tid);
}

#[test]
fn production_vision_pipeline_uses_media_core_motion_gate_and_emits_bounded_jfif_thumbnails() {
    use base64::Engine as _;

    struct CountingDetectBackend {
        inner: crate::backend::DeterministicStubBackend,
        detect_calls: AtomicUsize,
    }

    impl InferenceBackend for CountingDetectBackend {
        fn info(&self) -> InferenceBackendInfo {
            self.inner.info()
        }

        fn detect_objects(
            &self,
            frame: &RgbFrame,
            min_confidence: f32,
        ) -> Result<Vec<RawDetection>, MediaWorkerError> {
            self.detect_calls.fetch_add(1, Ordering::SeqCst);
            self.inner.detect_objects(frame, min_confidence)
        }

        fn encode_annotated_images(
            &self,
            regions: &[(&RgbFrame, Option<ObjectClass>, &[String])],
        ) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            self.inner.encode_annotated_images(regions)
        }

        fn encode_images(&self, images: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            self.inner.encode_images(images)
        }

        fn encode_text(&self, text: &str) -> Result<Vec<f32>, MediaWorkerError> {
            self.inner.encode_text(text)
        }
    }

    let models = ModelPinConfig::new("yolox-s", "2026.1", "siglip-b16-384", "2026.1", 768);
    let backend = Arc::new(CountingDetectBackend {
        inner: crate::backend::DeterministicStubBackend::new(models.clone()),
        detect_calls: AtomicUsize::new(0),
    });
    let pipeline = VisionPipeline::with_backend(
        models,
        true,
        Arc::clone(&backend) as Arc<dyn InferenceBackend>,
    )
    .with_tracking(TrackerMode::ByteTrack, true);

    let bg = RgbFrame::solid(320, 180, [46, 50, 56]);
    let mut person_frame = bg.clone();
    for y in 30..150u32 {
        for x in 40..90u32 {
            person_frame.set_pixel(x, y, [220, 30, 30]);
        }
    }

    // Sequence:
    // 0: empty anchor -> admitted (Stage 1 called, 0 dets, thumbnail emitted)
    // 1: identical static empty -> skipped BEFORE Stage 1 by media-core motion gate (suppressed, no thumbnail)
    // 2: identical static empty -> skipped BEFORE Stage 1 (suppressed, no thumbnail)
    // 3: red person enters -> motion admitted (Stage 1 called, 1 det, red color via media-core, thumbnail emitted)
    let frames = [&bg, &bg, &bg, &person_frame];
    let keyframes: Vec<ClipKeyframe<'_>> = frames
        .iter()
        .enumerate()
        .map(|(i, f)| ClipKeyframe::new((i as u64) * 1_000, f))
        .collect();

    let clip = pipeline
        .process_clip_keyframes(&keyframes)
        .expect("process clip through media-core stages");

    // Stage 1 detector was only invoked for frames 0 and 3 (skipped on static empty frames 1 & 2).
    assert_eq!(backend.detect_calls.load(Ordering::SeqCst), 2);
    assert_eq!(clip.frames().len(), 4);

    assert!(!clip.frames()[0].scene_suppressed());
    assert!(clip.frames()[0].thumbnail_jpeg_b64().is_some());

    for suppressed_idx in [1usize, 2usize] {
        assert!(clip.frames()[suppressed_idx].scene_suppressed());
        assert!(clip.frames()[suppressed_idx].detections().is_empty());
        assert!(clip.frames()[suppressed_idx].embeddings().is_empty());
        assert!(clip.frames()[suppressed_idx].thumbnail_jpeg_b64().is_none());
    }

    let f3 = &clip.frames()[3];
    assert!(!f3.scene_suppressed());
    assert_eq!(f3.detections().len(), 1);
    assert_eq!(f3.detections()[0].object_class(), ObjectClass::Person);
    assert!(
        f3.detections()[0]
            .dominant_colors()
            .contains(&"red".to_string()),
        "media-core HSV attribute extraction should classify red subject"
    );
    assert!(f3.detections()[0].track_id().is_some());

    let block_b64 = clip
        .block_thumbnail_jpeg_b64()
        .expect("detected block must emit block_thumbnail_jpeg_b64");
    let block_jpeg = base64::engine::general_purpose::STANDARD
        .decode(block_b64)
        .expect("decode block thumbnail JPEG");
    assert!(block_jpeg.starts_with(&[0xFF, 0xD8]));
    assert!(block_jpeg.ends_with(&[0xFF, 0xD9]));
    assert!(block_jpeg.len() <= crate::MAX_THUMBNAIL_JPEG_BYTES);

    // Frame 3 is already emitted as block_thumbnail_jpeg_b64 and is not duplicated on the frame.
    assert!(f3.thumbnail_jpeg_b64().is_none());
    assert_ne!(clip.frames()[0].thumbnail_jpeg_b64(), Some(block_b64));

    // Track summary points to its best keyframe (frame 3) without duplicating thumbnail bytes.
    assert_eq!(clip.tracks().len(), 1);
    assert_eq!(clip.tracks()[0].best_keyframe_offset_ms(), Some(3_000));
}
