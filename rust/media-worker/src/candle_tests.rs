//! Synthetic end-to-end tests for `CandleBackend`, `PureRustTokenizer`, `YoloV8Detector`,
//! `InferenceBackend` trait selection, and `/healthz` + `/readyz` backend metadata.
//!
//! All model weights, configs, tokenizers, and images in this module are 100% synthetic
//! and programmatically generated in temporary directories.

use crate::backend::InferencePrecision;
use crate::backend::{
    DeterministicStubBackend, InferenceBackend, InferenceBackendKind, InferenceDevicePreference,
    build_inference_backend,
};
use crate::candle_backend::{
    CandleBackend, CandleBackendOptions, cuda_jit_cache_dir, preprocess_siglip_batch,
    probe_writable_dir, resolve_candle_device,
};
use crate::capability::{
    GpuEnvironmentObservation, GpuEnvironmentProbe, verify_startup_capabilities_with_backend,
};
use crate::config::{CliArgs, ModelPinConfig, WorkerConfig};
use crate::errors::CapabilityError;
use crate::http_server::{ReadinessState, serve_http_probes};
use crate::metrics::WorkerMetrics;
use crate::ort_loader::OrtRuntimeProbeResult;
use crate::tokenizer::PureRustTokenizer;
use crate::vision::{ObjectClass, RgbFrame, VisionPipeline, cosine_similarity};
use crate::yolo_v8::{YoloV8Config, coco_class_to_object_class, coco_name_to_object_class};
use clap::Parser;
use safetensors::tensor::{Dtype as StDtype, TensorView};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use tempfile::TempDir;

struct StaticProbe(GpuEnvironmentObservation);

impl GpuEnvironmentProbe for StaticProbe {
    fn observe(
        &self,
        _config: &WorkerConfig,
    ) -> Result<GpuEnvironmentObservation, CapabilityError> {
        Ok(self.0.clone())
    }
}

/// Deterministic pseudo-random tensor generator for synthetic safetensors fixtures.
fn synth_f32_bytes(len: usize, seed: u64, scale: f32, bias: f32) -> Vec<u8> {
    let mut state = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut bytes = Vec::with_capacity(len * 4);
    for _ in 0..len {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let unit = ((state & 0xFFFF) as f32 / 32768.0) - 1.0;
        let val = unit * scale + bias;
        bytes.extend_from_slice(&val.to_le_bytes());
    }
    bytes
}

fn const_f32_bytes(len: usize, value: f32) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(len * 4);
    for _ in 0..len {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    bytes
}

type TensorMap = BTreeMap<String, (Vec<usize>, Vec<u8>)>;

fn next_seed(seed: &mut u64) -> u64 {
    *seed += 1;
    *seed
}

fn insert_linear(t: &mut TensorMap, seed: &mut u64, prefix: &str, out_d: usize, in_d: usize) {
    t.insert(
        format!("{prefix}.weight"),
        (
            vec![out_d, in_d],
            synth_f32_bytes(out_d * in_d, next_seed(seed), 0.25, 0.0),
        ),
    );
    t.insert(
        format!("{prefix}.bias"),
        (
            vec![out_d],
            synth_f32_bytes(out_d, next_seed(seed), 0.05, 0.0),
        ),
    );
}

fn insert_ln(t: &mut TensorMap, prefix: &str, dim: usize) {
    t.insert(
        format!("{prefix}.weight"),
        (vec![dim], const_f32_bytes(dim, 1.0)),
    );
    t.insert(
        format!("{prefix}.bias"),
        (vec![dim], const_f32_bytes(dim, 0.0)),
    );
}

fn insert_conv_block(
    t: &mut TensorMap,
    seed: &mut u64,
    prefix: &str,
    in_c: usize,
    out_c: usize,
    k: usize,
) {
    t.insert(
        format!("{prefix}.conv.weight"),
        (
            vec![out_c, in_c, k, k],
            synth_f32_bytes(out_c * in_c * k * k, next_seed(seed), 0.05, 0.0),
        ),
    );
    t.insert(
        format!("{prefix}.bn.weight"),
        (vec![out_c], const_f32_bytes(out_c, 1.0)),
    );
    t.insert(
        format!("{prefix}.bn.bias"),
        (vec![out_c], const_f32_bytes(out_c, 0.0)),
    );
    t.insert(
        format!("{prefix}.bn.running_mean"),
        (vec![out_c], const_f32_bytes(out_c, 0.0)),
    );
    t.insert(
        format!("{prefix}.bn.running_var"),
        (vec![out_c], const_f32_bytes(out_c, 1.0)),
    );
}

fn insert_c2f(
    t: &mut TensorMap,
    seed: &mut u64,
    prefix: &str,
    in_c: usize,
    out_c: usize,
    n: usize,
) {
    let c = out_c / 2;
    insert_conv_block(t, seed, &format!("{prefix}.cv1"), in_c, 2 * c, 1);
    insert_conv_block(t, seed, &format!("{prefix}.cv2"), (2 + n) * c, out_c, 1);
    for idx in 0..n {
        insert_conv_block(t, seed, &format!("{prefix}.bottleneck.{idx}.cv1"), c, c, 3);
        insert_conv_block(t, seed, &format!("{prefix}.bottleneck.{idx}.cv2"), c, c, 3);
    }
}

fn write_safetensors_file(path: &Path, tensors: &TensorMap) {
    let views: Vec<(String, TensorView<'_>)> = tensors
        .iter()
        .map(|(name, (shape, data))| {
            let tv = TensorView::new(StDtype::F32, shape.clone(), data)
                .expect("valid synthetic tensor view");
            (name.clone(), tv)
        })
        .collect();
    let encoded = safetensors::tensor::serialize(views, None).expect("serialize safetensors");
    std::fs::write(path, encoded).expect("write safetensors file");
}

/// Builds a tiny, structurally valid SigLIP checkpoint (`hidden_size=32`, `image_size=16`,
/// `patch_size=8`, 1 encoder layer, `vocab_size=32`) in `dir`.
fn write_tiny_siglip_fixture(dir: &Path) {
    let hidden = 32usize;
    let inter = 64usize;
    let heads = 4usize;
    let image_size = 16usize;
    let patch_size = 8usize;
    let num_patches = (image_size / patch_size).pow(2);
    let vocab_size = 32usize;
    let max_pos = 16usize;

    let config_json = serde_json::json!({
        "text_config": {
            "vocab_size": vocab_size,
            "hidden_size": hidden,
            "intermediate_size": inter,
            "num_hidden_layers": 1,
            "num_attention_heads": heads,
            "max_position_embeddings": max_pos,
            "hidden_act": "gelu_pytorch_tanh",
            "layer_norm_eps": 1e-6,
            "pad_token_id": 0,
            "bos_token_id": 1,
            "eos_token_id": 2
        },
        "vision_config": {
            "hidden_size": hidden,
            "intermediate_size": inter,
            "num_hidden_layers": 1,
            "num_attention_heads": heads,
            "num_channels": 3,
            "image_size": image_size,
            "patch_size": patch_size,
            "hidden_act": "gelu_pytorch_tanh",
            "layer_norm_eps": 1e-6
        }
    });
    std::fs::write(
        dir.join("config.json"),
        serde_json::to_vec_pretty(&config_json).expect("config json"),
    )
    .expect("write config.json");

    let tokenizer_json = serde_json::json!({
        "normalizer": { "type": "Lowercase" },
        "added_tokens": [
            { "id": 0, "content": "<pad>", "special": true },
            { "id": 1, "content": "<s>", "special": true },
            { "id": 2, "content": "</s>", "special": true },
            { "id": 3, "content": "<unk>", "special": true }
        ],
        "model": {
            "type": "Unigram",
            "unk_id": 3,
            "vocab": [
                ["<pad>", 0.0],
                ["<s>", 0.0],
                ["</s>", 0.0],
                ["<unk>", 0.0],
                ["\u{2581}person", -1.0],
                ["\u{2581}red", -1.1],
                ["\u{2581}jacket", -1.2],
                ["\u{2581}white", -1.1],
                ["\u{2581}van", -1.2],
                ["\u{2581}vehicle", -1.3],
                ["\u{2581}bicycle", -1.4],
                ["\u{2581}dog", -1.4],
                ["\u{2581}package", -1.4],
                ["\u{2581}synthetic", -1.5],
                ["\u{2581}warmup", -1.5],
                ["\u{2581}query", -1.5],
                ["\u{2581}in", -1.0],
                ["\u{2581}a", -1.0],
                ["\u{2581}", -2.0],
                ["p", -3.0],
                ["e", -3.0],
                ["r", -3.0],
                ["s", -3.0],
                ["o", -3.0],
                ["n", -3.0],
                ["a", -3.0],
                ["t", -3.0],
                ["i", -3.0],
                ["c", -3.0],
                ["d", -3.0],
                ["u", -3.0],
                ["y", -3.0]
            ]
        }
    });
    std::fs::write(
        dir.join("tokenizer.json"),
        serde_json::to_vec_pretty(&tokenizer_json).expect("tokenizer json"),
    )
    .expect("write tokenizer.json");

    let mut t = TensorMap::new();
    let mut seed = 100u64;

    // Vision embeddings
    t.insert(
        "vision_model.embeddings.patch_embedding.weight".to_string(),
        (
            vec![hidden, 3, patch_size, patch_size],
            synth_f32_bytes(
                hidden * 3 * patch_size * patch_size,
                next_seed(&mut seed),
                0.2,
                0.0,
            ),
        ),
    );
    t.insert(
        "vision_model.embeddings.patch_embedding.bias".to_string(),
        (
            vec![hidden],
            synth_f32_bytes(hidden, next_seed(&mut seed), 0.05, 0.0),
        ),
    );
    t.insert(
        "vision_model.embeddings.position_embedding.weight".to_string(),
        (
            vec![num_patches, hidden],
            synth_f32_bytes(num_patches * hidden, next_seed(&mut seed), 0.1, 0.0),
        ),
    );

    // Vision encoder layer 0
    for proj in ["q_proj", "k_proj", "v_proj", "out_proj"] {
        insert_linear(
            &mut t,
            &mut seed,
            &format!("vision_model.encoder.layers.0.self_attn.{proj}"),
            hidden,
            hidden,
        );
    }
    insert_ln(&mut t, "vision_model.encoder.layers.0.layer_norm1", hidden);
    insert_linear(
        &mut t,
        &mut seed,
        "vision_model.encoder.layers.0.mlp.fc1",
        inter,
        hidden,
    );
    insert_linear(
        &mut t,
        &mut seed,
        "vision_model.encoder.layers.0.mlp.fc2",
        hidden,
        inter,
    );
    insert_ln(&mut t, "vision_model.encoder.layers.0.layer_norm2", hidden);
    insert_ln(&mut t, "vision_model.post_layernorm", hidden);

    // Vision pooling head
    t.insert(
        "vision_model.head.probe".to_string(),
        (
            vec![1, 1, hidden],
            synth_f32_bytes(hidden, next_seed(&mut seed), 0.2, 0.0),
        ),
    );
    t.insert(
        "vision_model.head.attention.in_proj_weight".to_string(),
        (
            vec![3 * hidden, hidden],
            synth_f32_bytes(3 * hidden * hidden, next_seed(&mut seed), 0.2, 0.0),
        ),
    );
    t.insert(
        "vision_model.head.attention.in_proj_bias".to_string(),
        (
            vec![3 * hidden],
            synth_f32_bytes(3 * hidden, next_seed(&mut seed), 0.05, 0.0),
        ),
    );
    insert_linear(
        &mut t,
        &mut seed,
        "vision_model.head.attention.out_proj",
        hidden,
        hidden,
    );
    insert_ln(&mut t, "vision_model.head.layernorm", hidden);
    insert_linear(
        &mut t,
        &mut seed,
        "vision_model.head.mlp.fc1",
        inter,
        hidden,
    );
    insert_linear(
        &mut t,
        &mut seed,
        "vision_model.head.mlp.fc2",
        hidden,
        inter,
    );

    // Text embeddings
    t.insert(
        "text_model.embeddings.token_embedding.weight".to_string(),
        (
            vec![vocab_size, hidden],
            synth_f32_bytes(vocab_size * hidden, next_seed(&mut seed), 0.3, 0.0),
        ),
    );
    t.insert(
        "text_model.embeddings.position_embedding.weight".to_string(),
        (
            vec![max_pos, hidden],
            synth_f32_bytes(max_pos * hidden, next_seed(&mut seed), 0.1, 0.0),
        ),
    );

    // Text encoder layer 0
    for proj in ["q_proj", "k_proj", "v_proj", "out_proj"] {
        insert_linear(
            &mut t,
            &mut seed,
            &format!("text_model.encoder.layers.0.self_attn.{proj}"),
            hidden,
            hidden,
        );
    }
    insert_ln(&mut t, "text_model.encoder.layers.0.layer_norm1", hidden);
    insert_linear(
        &mut t,
        &mut seed,
        "text_model.encoder.layers.0.mlp.fc1",
        inter,
        hidden,
    );
    insert_linear(
        &mut t,
        &mut seed,
        "text_model.encoder.layers.0.mlp.fc2",
        hidden,
        inter,
    );
    insert_ln(&mut t, "text_model.encoder.layers.0.layer_norm2", hidden);
    insert_ln(&mut t, "text_model.final_layer_norm", hidden);
    insert_linear(&mut t, &mut seed, "text_model.head", hidden, hidden);

    // Logit scale & bias
    t.insert(
        "logit_scale".to_string(),
        (vec![1], const_f32_bytes(1, 2.3)),
    );
    t.insert(
        "logit_bias".to_string(),
        (vec![1], const_f32_bytes(1, -10.0)),
    );

    let delta = 1.0_f32 / 4096.0;
    for (head, biases) in [
        ("vision_model.head.attention.out_proj", &[1.0, 1.0, 0.0][..]),
        ("vision_model.head.mlp.fc1", &[8.0, 8.0]),
        ("vision_model.head.mlp.fc2", &[0.0, delta, -8.0]),
        ("text_model.head", &[1.0, 1.0 + delta, -8.0]),
    ] {
        let (shape, weights) = t.get_mut(&format!("{head}.weight")).expect("head weights");
        let row_bytes = shape[1] * size_of::<f32>();
        weights[..biases.len() * row_bytes].fill(0);
        if matches!(head, "vision_model.head.mlp.fc2" | "text_model.head") {
            let third_row = &mut weights[2 * row_bytes..3 * row_bytes];
            third_row[..4].copy_from_slice(&1.0_f32.to_le_bytes());
            third_row[4..8].copy_from_slice(&delta.to_le_bytes());
        }
        let (_, bias) = t.get_mut(&format!("{head}.bias")).expect("head bias");
        for (slot, value) in bias.chunks_exact_mut(4).zip(biases) {
            slot.copy_from_slice(&value.to_le_bytes());
        }
    }
    for (parameter, value) in [("weight", 0.0), ("bias", 8.0_f32)] {
        let (_, data) = t
            .get_mut(&format!("text_model.final_layer_norm.{parameter}"))
            .expect("text output normalization");
        data[..8].copy_from_slice(&const_f32_bytes(2, value));
    }
    write_safetensors_file(&dir.join("model.safetensors"), &t);
}

/// Builds a tiny valid YOLOv8 `.safetensors` + `detector_config.json` (`input_size=64`)
/// with a positive bias on COCO class 0 (`person`) so Stage 1 emits real detections.
fn write_tiny_yolov8_fixture(dir: &Path) {
    let cfg = YoloV8Config {
        depth: 0.33,
        width: 0.0625,
        ratio: 1.0,
        num_classes: 10,
        input_size: 64,
    };
    std::fs::write(
        dir.join("detector_config.json"),
        serde_json::to_vec_pretty(&cfg).expect("detector_config json"),
    )
    .expect("write detector_config.json");

    let b1 = 4usize;
    let b2 = 8usize;
    let f1 = 16usize;
    let f2 = 32usize;
    let f3 = 32usize;
    let ch = 16usize;
    let nc = cfg.num_classes;
    let c1 = (f1 / 4).max(ch * 4).max(16);
    let c2 = f1.max(nc.min(100));

    let mut t = TensorMap::new();
    let mut seed = 500u64;

    // Backbone (`net.*`)
    insert_conv_block(&mut t, &mut seed, "net.b1.0", 3, b1, 3);
    insert_conv_block(&mut t, &mut seed, "net.b1.1", b1, b2, 3);
    insert_c2f(&mut t, &mut seed, "net.b2.0", b2, b2, 1);
    insert_conv_block(&mut t, &mut seed, "net.b2.1", b2, f1, 3);
    insert_c2f(&mut t, &mut seed, "net.b2.2", f1, f1, 2);
    insert_conv_block(&mut t, &mut seed, "net.b3.0", f1, f2, 3);
    insert_c2f(&mut t, &mut seed, "net.b3.1", f2, f2, 2);
    insert_conv_block(&mut t, &mut seed, "net.b4.0", f2, f3, 3);
    insert_c2f(&mut t, &mut seed, "net.b4.1", f3, f3, 1);
    insert_conv_block(&mut t, &mut seed, "net.b5.0.cv1", f3, f3 / 2, 1);
    insert_conv_block(&mut t, &mut seed, "net.b5.0.cv2", (f3 / 2) * 4, f3, 1);

    // Neck (`fpn.*`)
    insert_c2f(&mut t, &mut seed, "fpn.n1", f2 + f3, f2, 1);
    insert_c2f(&mut t, &mut seed, "fpn.n2", f1 + f2, f1, 1);
    insert_conv_block(&mut t, &mut seed, "fpn.n3", f1, f1, 3);
    insert_c2f(&mut t, &mut seed, "fpn.n4", f1 + f2, f2, 1);
    insert_conv_block(&mut t, &mut seed, "fpn.n5", f2, f2, 3);
    insert_c2f(&mut t, &mut seed, "fpn.n6", f2 + f3, f3, 1);

    // Head (`head.*`)
    let mut dfl_weights = Vec::with_capacity(ch * 4);
    for i in 0..ch {
        dfl_weights.extend_from_slice(&(i as f32).to_le_bytes());
    }
    t.insert(
        "head.dfl.conv.weight".to_string(),
        (vec![1, ch, 1, 1], dfl_weights),
    );

    for (idx, in_c) in [f1, f2, f3].into_iter().enumerate() {
        insert_conv_block(&mut t, &mut seed, &format!("head.cv2.{idx}.0"), in_c, c1, 3);
        insert_conv_block(&mut t, &mut seed, &format!("head.cv2.{idx}.1"), c1, c1, 3);
        t.insert(
            format!("head.cv2.{idx}.2.weight"),
            (vec![4 * ch, c1, 1, 1], const_f32_bytes(4 * ch * c1, 0.0)),
        );
        t.insert(
            format!("head.cv2.{idx}.2.bias"),
            (vec![4 * ch], const_f32_bytes(4 * ch, 0.0)),
        );

        insert_conv_block(&mut t, &mut seed, &format!("head.cv3.{idx}.0"), in_c, c2, 3);
        insert_conv_block(&mut t, &mut seed, &format!("head.cv3.{idx}.1"), c2, c2, 3);
        t.insert(
            format!("head.cv3.{idx}.2.weight"),
            (vec![nc, c2, 1, 1], const_f32_bytes(nc * c2, 0.0)),
        );
        // Set strong positive logit on class 0 (`person`) for scale 2 so sigmoid > 0.85,
        // and negative logits elsewhere so NMS produces clean deterministic detections.
        let mut cls_bias = Vec::with_capacity(nc * 4);
        for class_i in 0..nc {
            let val = if idx == 2 && class_i == 0 {
                2.2f32
            } else {
                -4.0f32
            };
            cls_bias.extend_from_slice(&val.to_le_bytes());
        }
        t.insert(format!("head.cv3.{idx}.2.bias"), (vec![nc], cls_bias));
    }

    write_safetensors_file(&dir.join("detector.safetensors"), &t);
}

#[test]
fn candle_backend_synthetic_siglip_end_to_end_and_scene_only_fallback() {
    let dir = TempDir::new().expect("temp dir");
    write_tiny_siglip_fixture(dir.path());

    let backend = CandleBackend::load(
        dir.path(),
        &CandleBackendOptions::new(InferenceDevicePreference::Cpu, false, 32)
            .with_model_revision("siglip-tiny-synth:1"),
    )
    .expect("load synthetic SigLIP CandleBackend");

    let info = backend.info();
    assert_eq!(info.backend(), InferenceBackendKind::Candle);
    assert_eq!(info.device(), "cpu");
    assert_eq!(info.embedding_dim(), 32);
    assert_eq!(info.model_revision(), "siglip-tiny-synth:1");
    assert!(!info.detector_enabled());

    // Scene-only fallback when detector weights are absent.
    let frame_a = RgbFrame::solid(32, 24, [210, 40, 30]);
    let frame_b = RgbFrame::solid(32, 24, [30, 80, 220]);
    let dets = backend
        .detect_objects(&frame_a, 0.35)
        .expect("scene-only fallback must succeed");
    assert!(dets.is_empty());

    // Batch image encoding: finite, L2-normalized, deterministic.
    let img_embs = backend
        .encode_images(&[&frame_a, &frame_b])
        .expect("encode_images");
    assert_eq!(img_embs.len(), 2);
    for emb in &img_embs {
        assert_eq!(emb.len(), 32);
        assert!(emb.iter().all(|v| v.is_finite()));
        let norm: f32 = emb.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4, "expected unit norm, got {norm}");
    }
    let img_embs_repeat = backend
        .encode_images(&[&frame_a])
        .expect("repeat encode_images");
    let self_sim = cosine_similarity(&img_embs[0], &img_embs_repeat[0]);
    assert!(
        (self_sim - 1.0).abs() < 1e-5,
        "repeated image encoding must be deterministic, got {self_sim}"
    );

    // Text encoding: finite, L2-normalized, deterministic, same vector space.
    let text_a = backend
        .encode_text("person in red jacket")
        .expect("encode_text");
    let text_a_repeat = backend
        .encode_text("  PERSON   in red jacket ")
        .expect("encode_text normalized repeat");
    let text_b = backend.encode_text("white van").expect("encode_text b");
    assert_eq!(text_a.len(), 32);
    assert!(text_a.iter().all(|v| v.is_finite()));
    let text_norm: f32 = text_a.iter().map(|v| v * v).sum::<f32>().sqrt();
    assert!((text_norm - 1.0).abs() < 1e-4);
    assert!(
        (cosine_similarity(&text_a, &text_a_repeat) - 1.0).abs() < 1e-5,
        "text encoding must be deterministic across whitespace/case normalization"
    );
    let cross_sim = cosine_similarity(&img_embs[0], &text_a);
    assert!(cross_sim.is_finite() && (-1.0001..=1.0001).contains(&cross_sim));
    assert_ne!(text_a, text_b);

    // End-to-end VisionPipeline::process_keyframe with CandleBackend.
    let models = ModelPinConfig::new("none", "1", "siglip-tiny-synth", "1", 32);
    let pipeline = VisionPipeline::with_backend(models, true, Arc::new(backend));
    let analysis = pipeline
        .process_keyframe(&frame_a, None)
        .expect("process_keyframe");
    assert!(!analysis.scene_suppressed());
    assert!(analysis.detections().is_empty());
    assert_eq!(analysis.embeddings().len(), 1);
    assert_eq!(analysis.embeddings()[0].region_kind(), "scene");
    assert_eq!(analysis.embeddings()[0].embedding().len(), 32);
    assert!(
        (cosine_similarity(analysis.embeddings()[0].embedding(), &img_embs[0]) - 1.0).abs() < 1e-5
    );
}

#[test]
fn candle_backend_with_synthetic_yolov8_detector_runs_two_stage_pipeline() {
    let dir = TempDir::new().expect("temp dir");
    write_tiny_siglip_fixture(dir.path());
    write_tiny_yolov8_fixture(dir.path());

    let backend = Arc::new(
        CandleBackend::load(
            dir.path(),
            &CandleBackendOptions::new(InferenceDevicePreference::Auto, false, 32)
                .with_model_revision("siglip-yolo-synth:1"),
        )
        .expect("load SigLIP + YOLOv8 CandleBackend"),
    );

    assert!(backend.detector_enabled());
    assert_eq!(backend.info().device(), "cpu");

    let frame = RgbFrame::solid(64, 64, [180, 35, 35]);
    let raw_dets = backend
        .detect_objects(&frame, 0.35)
        .expect("YOLOv8 detect_objects");
    assert!(
        !raw_dets.is_empty(),
        "expected synthetic YOLOv8 person detection"
    );
    assert!(
        raw_dets
            .iter()
            .all(|d| d.object_class() == ObjectClass::Person)
    );

    let models = ModelPinConfig::new("yolov8-tiny", "1", "siglip-yolo-synth", "1", 32);
    let pipeline = VisionPipeline::with_backend(models, true, backend);
    let analysis = pipeline
        .process_keyframe(&frame, None)
        .expect("two-stage process_keyframe");

    assert!(!analysis.detections().is_empty());
    assert!(analysis.embeddings().len() >= 2);
    assert_eq!(analysis.embeddings()[0].region_kind(), "scene");
    assert_eq!(analysis.embeddings()[1].region_kind(), "crop");
    assert_eq!(analysis.embeddings()[1].object_class(), Some("person"));
    for emb in analysis.embeddings() {
        assert_eq!(emb.embedding().len(), 32);
        let norm: f32 = emb.embedding().iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4);
    }
}

#[test]
fn coco_class_mapping_covers_all_required_surveillance_classes() {
    assert_eq!(coco_class_to_object_class(0), Some(ObjectClass::Person));
    assert_eq!(coco_class_to_object_class(1), Some(ObjectClass::Bicycle));
    for id in [2, 3, 5, 7] {
        assert_eq!(coco_class_to_object_class(id), Some(ObjectClass::Vehicle));
    }
    for id in [14, 15, 16, 17, 18, 19, 21] {
        assert_eq!(coco_class_to_object_class(id), Some(ObjectClass::Animal));
    }
    for id in [24, 26, 28] {
        assert_eq!(coco_class_to_object_class(id), Some(ObjectClass::Package));
    }
    assert_eq!(coco_class_to_object_class(39), None); // bottle
    assert_eq!(coco_class_to_object_class(999), None);

    assert_eq!(
        coco_name_to_object_class("person"),
        Some(ObjectClass::Person)
    );
    for name in ["car", "truck", "bus", "motorcycle"] {
        assert_eq!(coco_name_to_object_class(name), Some(ObjectClass::Vehicle));
    }
    assert_eq!(
        coco_name_to_object_class("bicycle"),
        Some(ObjectClass::Bicycle)
    );
    for name in ["dog", "cat", "bird", "horse", "sheep", "cow", "bear"] {
        assert_eq!(coco_name_to_object_class(name), Some(ObjectClass::Animal));
    }
    for name in ["backpack", "suitcase", "handbag"] {
        assert_eq!(coco_name_to_object_class(name), Some(ObjectClass::Package));
    }
    assert_eq!(coco_name_to_object_class("toaster"), None);
}

#[test]
fn candle_backend_error_handling_for_missing_or_corrupt_artifacts_and_gpu_fail_closed() {
    let cpu_options = || CandleBackendOptions::new(InferenceDevicePreference::Cpu, false, 32);
    let missing = Path::new("/nonexistent/serviceradar/synthetic/model_dir");
    assert!(CandleBackend::load(missing, &cpu_options()).is_err());

    let dir = TempDir::new().expect("temp dir");
    // Missing config.json
    assert!(CandleBackend::load(dir.path(), &cpu_options()).is_err());

    // Valid config.json but missing model.safetensors
    write_tiny_siglip_fixture(dir.path());
    std::fs::remove_file(dir.path().join("model.safetensors")).expect("remove weights");
    assert!(CandleBackend::load(dir.path(), &cpu_options()).is_err());

    // Corrupted safetensors bytes
    std::fs::write(
        dir.path().join("model.safetensors"),
        b"not-a-safetensors-file",
    )
    .expect("write corrupt weights");
    assert!(CandleBackend::load(dir.path(), &cpu_options()).is_err());

    // A checkpoint whose towers emit a different width than the configured index
    // (the fixture declares 32-d towers) must be refused at load, not indexed.
    write_tiny_siglip_fixture(dir.path());
    let width_err = CandleBackend::load(
        dir.path(),
        &CandleBackendOptions::new(InferenceDevicePreference::Cpu, false, 768),
    )
    .expect_err("a 32-d checkpoint must not load as a 768-d embedder");
    assert!(
        width_err.to_string().contains("32-d image and 32-d text"),
        "unexpected width error: {width_err}"
    );

    // Valid weights + config, missing tokenizer.json
    write_tiny_siglip_fixture(dir.path());
    std::fs::remove_file(dir.path().join("tokenizer.json")).expect("remove tokenizer");
    assert!(CandleBackend::load(dir.path(), &cpu_options()).is_err());

    // Device policy: GPU strictly required with CPU preference must fail closed!
    assert!(resolve_candle_device(InferenceDevicePreference::Cpu, true).is_err());

    // cpu_explicit never picks up a GPU, in any build: `cuda` is a conflict and `auto`
    // follows the provider to the CPU.
    assert!(resolve_candle_device(InferenceDevicePreference::Cuda, false).is_err());
    let (_, auto_cpu) = resolve_candle_device(InferenceDevicePreference::Auto, false)
        .expect("auto with cpu_explicit resolves to the CPU");
    assert_eq!(auto_cpu, "cpu");

    // Without the `cuda` Cargo feature, a GPU provider must fail closed (never silent CPU).
    #[cfg(not(feature = "cuda"))]
    assert!(resolve_candle_device(InferenceDevicePreference::Auto, true).is_err());
}

#[tokio::test]
async fn backend_selection_and_http_probes_expose_active_backend_and_device() {
    let dir = TempDir::new().expect("temp dir");
    write_tiny_siglip_fixture(dir.path());

    let conflict = CliArgs::try_parse_from([
        "serviceradar-media-worker",
        "--device",
        "cuda",
        "--execution-provider",
        "cpu_explicit",
    ])
    .expect("parse conflicting arguments")
    .into_worker_config()
    .expect_err("conflicting device and provider must fail before choosing the backend");
    assert!(
        conflict
            .to_string()
            .contains("execution_provider=cpu_explicit")
    );

    let default = CliArgs::try_parse_from(["serviceradar-media-worker"])
        .expect("parse default cli")
        .into_worker_config()
        .expect("default config");
    assert_eq!(default.backend_kind(), InferenceBackendKind::Candle);
    let error = build_inference_backend(&default)
        .err()
        .expect("Candle requires a checkpoint");
    assert!(error.to_string().contains("MEDIA_WORKER_MODEL_DIR"));

    for value in ["CANDLE", "  cAnDlE  ", "", "   "] {
        let config = CliArgs::try_parse_from(["serviceradar-media-worker", "--backend", value])
            .expect("accepted Candle spelling")
            .into_worker_config()
            .expect("worker config");
        assert_eq!(config.backend_kind(), InferenceBackendKind::Candle);
    }
    for value in ["deterministic", "STUB", " stub ", "other"] {
        assert!(
            CliArgs::try_parse_from(["serviceradar-media-worker", "--backend", value]).is_err()
        );
    }

    let cli_stub = CliArgs::try_parse_from([
        "serviceradar-media-worker",
        "--backend",
        "stub",
        "--execution-provider",
        "cpu_explicit",
    ])
    .expect("parse stub cli");
    let cfg_stub = cli_stub.into_worker_config().expect("stub config");
    assert_eq!(cfg_stub.backend_kind(), InferenceBackendKind::Stub);
    let stub_backend = build_inference_backend(&cfg_stub).expect("build stub backend");
    assert_eq!(stub_backend.info().backend(), InferenceBackendKind::Stub);
    assert_eq!(stub_backend.info().device(), "cpu");

    let cli_auto_candle = CliArgs::try_parse_from([
        "serviceradar-media-worker",
        "--execution-provider",
        "cpu_explicit",
        "--model-dir",
        dir.path().to_str().expect("utf8 path"),
        "--device",
        "cpu",
        "--embedding-dim",
        "32",
    ])
    .expect("parse candle cli");
    let cfg_candle = cli_auto_candle.into_worker_config().expect("candle config");
    assert_eq!(cfg_candle.backend_kind(), InferenceBackendKind::Candle);
    assert_eq!(
        cfg_candle.device_preference(),
        InferenceDevicePreference::Cpu
    );
    assert_eq!(cfg_candle.precision(), InferencePrecision::Auto);
    for (raw, expected) in [
        ("f16", Some(InferencePrecision::F16)),
        ("auto", Some(InferencePrecision::Auto)),
        ("f32", Some(InferencePrecision::F32)),
        ("F32", None),
        (" f16 ", None),
        ("bf16", None),
    ] {
        let parsed = CliArgs::try_parse_from(["serviceradar-media-worker", "--dtype", raw])
            .expect("parse dtype cli")
            .into_worker_config()
            .map(|cfg| cfg.precision());
        assert_eq!(parsed.ok(), expected, "MEDIA_WORKER_DTYPE={raw}");
    }

    let candle_backend = build_inference_backend(&cfg_candle).expect("build candle backend");
    assert_eq!(
        candle_backend.info().backend(),
        InferenceBackendKind::Candle
    );
    assert_eq!(candle_backend.info().device(), "cpu");
    assert_eq!(candle_backend.info().embedding_dim(), 32);

    // 3. Startup capability verification + /healthz & /readyz expose backend and device.
    let probe = StaticProbe(GpuEnvironmentObservation::new(
        0,
        false,
        false,
        None,
        None,
        OrtRuntimeProbeResult::unavailable(),
    ));
    let manifest =
        verify_startup_capabilities_with_backend(&cfg_candle, &probe, Arc::clone(&candle_backend))
            .expect("candle startup capability admission");
    assert_eq!(manifest.inference_backend(), InferenceBackendKind::Candle);
    assert_eq!(manifest.inference_device(), "cpu");
    assert!(!manifest.detector_enabled());
    assert_eq!(manifest.embedding_dim(), 32);

    let state = ReadinessState::ready(manifest, Arc::new(WorkerMetrics::new()));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let addr = serve_http_probes(SocketAddr::from(([127, 0, 0, 1], 0)), state, shutdown_rx)
        .await
        .expect("serve_http_probes");

    let healthz_url = format!("http://{addr}/healthz");
    let healthz_json: serde_json::Value = tokio::task::spawn_blocking(move || {
        ureq::get(&healthz_url)
            .call()
            .expect("GET /healthz")
            .body_mut()
            .read_json()
            .expect("healthz json")
    })
    .await
    .expect("join healthz");
    assert_eq!(healthz_json["status"], "ok");
    assert_eq!(healthz_json["backend"], "candle");
    assert_eq!(healthz_json["device"], "cpu");

    let readyz_url = format!("http://{addr}/readyz");
    let readyz_json: serde_json::Value = tokio::task::spawn_blocking(move || {
        ureq::get(&readyz_url)
            .call()
            .expect("GET /readyz")
            .body_mut()
            .read_json()
            .expect("readyz json")
    })
    .await
    .expect("join readyz");
    assert_eq!(readyz_json["inference_backend"], "candle");
    assert_eq!(readyz_json["inference_device"], "cpu");
    assert_eq!(readyz_json["inference_dtype"], "f32");
    assert_eq!(readyz_json["detector_enabled"], false);
    assert_eq!(readyz_json["embedding_dim"], 32);

    let _ = shutdown_tx.send(true);

    // Explicit stub backend via DeterministicStubBackend also satisfies InferenceBackend.
    let stub = DeterministicStubBackend::new(WorkerConfig::cpu_explicit_default().models().clone());
    let stub_vec = stub.encode_text("red bicycle").expect("stub text");
    assert_eq!(stub_vec.len(), 768);
}

#[test]
fn pure_rust_tokenizer_supports_bpe_and_wordpiece_formats() {
    let bpe_json = serde_json::json!({
        "normalizer": { "type": "Lowercase" },
        "added_tokens": [
            { "id": 0, "content": "<pad>", "special": true },
            { "id": 1, "content": "<|endoftext|>", "special": true }
        ],
        "model": {
            "type": "BPE",
            "unk_token": "<unk>",
            "end_of_word_suffix": "</w>",
            "vocab": {
                "<pad>": 0,
                "<|endoftext|>": 1,
                "<unk>": 2,
                "r": 3,
                "e": 4,
                "d</w>": 5,
                "re": 6,
                "red</w>": 7
            },
            "merges": ["r e", "re d</w>"]
        }
    });
    let bpe = PureRustTokenizer::from_bytes(&serde_json::to_vec(&bpe_json).unwrap())
        .expect("parse BPE tokenizer");
    assert_eq!(bpe.encode_raw("Red"), vec![7]);
    let padded = bpe.encode_padded("Red", 4, 0, 1, 8).expect("pad BPE");
    assert_eq!(padded, vec![7, 1, 0, 0]);

    let wp_json = serde_json::json!({
        "normalizer": { "type": "Lowercase" },
        "model": {
            "type": "WordPiece",
            "unk_token": "[UNK]",
            "continuing_subword_prefix": "##",
            "vocab": {
                "[PAD]": 0,
                "[SEP]": 1,
                "[UNK]": 2,
                "van": 3,
                "##s": 4
            }
        }
    });
    let wp = PureRustTokenizer::from_bytes(&serde_json::to_vec(&wp_json).unwrap())
        .expect("parse WordPiece tokenizer");
    assert_eq!(wp.encode_raw("vans"), vec![3, 4]);
}

/// Synthetic frames of assorted sizes (including non-square and odd ones) with
/// per-pixel gradients, so bilinear sampling differs per output position.
fn gradient_frames() -> Vec<RgbFrame> {
    [(32u32, 24u32), (7, 5), (64, 48), (16, 16), (33, 17)]
        .iter()
        .enumerate()
        .map(|(i, &(w, h))| {
            let mut px = Vec::with_capacity((w * h * 3) as usize);
            for y in 0..h {
                for x in 0..w {
                    px.extend_from_slice(&[
                        ((x * 37 + y * 11 + i as u32 * 5) % 256) as u8,
                        ((x * 3 + y * 91) % 256) as u8,
                        ((x ^ y) * 13 % 256) as u8,
                    ]);
                }
            }
            RgbFrame::from_rgb8(w, h, px).expect("synthetic gradient frame")
        })
        .collect()
}

#[test]
fn parallel_siglip_preprocessing_matches_single_threaded_output_bit_for_bit() {
    let red_blue = RgbFrame::from_rgb8(2, 1, vec![255, 0, 0, 0, 0, 255]).unwrap();
    let green = RgbFrame::solid(1, 1, [0, 255, 0]);
    let pixels = preprocess_siglip_batch(&[&red_blue, &green], 3, 2);
    let planes = [
        [1., 0., -1.],
        [-1.; 3],
        [-1., 0., 1.],
        [-1.; 3],
        [1.; 3],
        [-1.; 3],
    ];
    let expected: Vec<f32> = planes.iter().flat_map(|row| row.repeat(3)).collect();
    assert_eq!(pixels, expected);

    let frames = gradient_frames();
    let refs: Vec<&RgbFrame> = frames.iter().collect();
    let target = 12;
    let sequential = preprocess_siglip_batch(&refs, target, 1);
    assert_eq!(sequential.len(), refs.len() * 3 * target * target);

    // Thread counts that divide the batch evenly, unevenly, and exceed it.
    for threads in [2, 3, 4, 64] {
        let parallel = preprocess_siglip_batch(&refs, target, threads);
        let identical = sequential.len() == parallel.len()
            && sequential
                .iter()
                .zip(&parallel)
                .all(|(a, b)| a.to_bits() == b.to_bits());
        assert!(
            identical,
            "{threads} preprocessing threads changed the output"
        );
    }
}

#[tokio::test]
async fn nats_worker_entry_points_refuse_failed_admission_before_connecting() {
    let config = WorkerConfig::default()
        .with_backend_kind(InferenceBackendKind::Stub)
        .with_execution_provider(crate::ExecutionProvider::CpuExplicit)
        .with_concurrency(3, 1)
        .with_nats_url("invalid://");
    let backend = build_inference_backend(&config).expect("load CPU stub");
    let metrics = Arc::new(WorkerMetrics::new());
    let (_shutdown, rx) = tokio::sync::watch::channel(false);
    let configured =
        crate::run_nats_worker_loops(config.clone(), metrics.clone(), rx.clone()).await;
    let supplied = crate::run_nats_worker_loops_with_backend(config, backend, metrics, rx).await;
    for result in [configured, supplied] {
        let error = result.expect_err("invalid CPU worker must fail before NATS setup");
        assert!(
            error.to_string().contains("index_concurrency <= 2"),
            "{error}"
        );
    }
}

#[test]
fn candle_f16_embeddings_stay_in_the_f32_vector_space() {
    let dir = TempDir::new().expect("temp dir");
    write_tiny_siglip_fixture(dir.path());
    let identity = ("synthetic-siglip", "rounding-fixture-v1", 32);
    let load = |dtype| {
        let config = CliArgs::try_parse_from([
            "serviceradar-media-worker",
            "--backend",
            "candle",
            "--execution-provider",
            "cpu_explicit",
            "--model-dir",
            dir.path().to_str().expect("checkpoint path"),
            "--dtype",
            dtype,
            "--embedder-model-id",
            identity.0,
            "--embedder-model-version",
            identity.1,
            "--embedding-dim",
            "32",
        ])
        .expect("parse precision configuration")
        .into_worker_config()
        .expect("worker config");
        let backend = build_inference_backend(&config).expect("load configured synthetic SigLIP");
        let manifest = verify_startup_capabilities_with_backend(
            &config,
            &StaticProbe(GpuEnvironmentObservation::no_gpu()),
            Arc::clone(&backend),
        )
        .expect("admit configured synthetic SigLIP");
        assert_eq!(
            (
                manifest.embedder_model_id(),
                manifest.embedder_model_version(),
                manifest.embedding_dim()
            ),
            identity
        );
        backend
    };
    let f32_backend = load("auto");
    let f16_backend = load("f16");
    // `auto` is f32 on the CPU; an explicit f16 is honoured and reported.
    assert_eq!(f32_backend.info().dtype(), InferencePrecision::F32);
    assert_eq!(f16_backend.info().dtype(), InferencePrecision::F16);
    // The model identity must not depend on precision (search interchangeability).
    assert_eq!(
        f32_backend.info().model_revision(),
        f16_backend.info().model_revision()
    );

    let frames = gradient_frames();
    let refs: Vec<&RgbFrame> = frames.iter().collect();
    let full_images = f32_backend.encode_images(&refs).expect("f32 images");
    let half_images = f16_backend.encode_images(&refs).expect("f16 images");
    assert_eq!(full_images.len(), frames.len());
    assert_eq!(half_images.len(), frames.len());
    let mut pairs: Vec<_> = full_images.into_iter().zip(half_images).collect();
    for query in ["person in red jacket", "white van"] {
        pairs.push((
            f32_backend.encode_text(query).expect("f32 text"),
            f16_backend.encode_text(query).expect("f16 text"),
        ));
    }

    // The real SigLIP base model measured a minimum f16-vs-f32 cosine of 0.9999983 on
    // GPU; this tiny checkpoint lands near 0.99999. The 0.9999 bar sits clear of f16
    // rounding noise and far above what a wrong cast or a missing upcast produces.
    for (full, half) in &pairs {
        assert_eq!(full.len(), 32);
        assert_eq!(half.len(), 32);
        assert!(half[0] > 0.0);
        assert_eq!(half[0], half[1], "binary16 rounds 1 + 2^-12 to 1");
        assert!((full[1] / full[0] - (1.0 + 1.0 / 4096.0)).abs() < 1e-6);
        assert_eq!(
            half[2], 0.0,
            "binary16 rounds 8 + 2^-9 to 8 before subtracting 8"
        );
        assert!((full[2] / full[0] - 1.0 / 512.0).abs() < 1e-7);
        let norm: f32 = half.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!(
            (norm - 1.0).abs() < 1e-4,
            "f16 output must be L2-normalised f32"
        );
        let cos = cosine_similarity(full, half);
        assert!(cos > 0.9999, "f16 drifted from f32: cosine {cos}");
    }
}

#[test]
fn cuda_jit_cache_location_follows_cuda_driver_rules_and_unwritable_is_reported() {
    type EnvVars = &'static [(&'static str, &'static str)];
    let env = |pairs: EnvVars| {
        move |key: &str| {
            pairs
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| OsString::from(v))
        }
    };
    let cases: [(EnvVars, Option<&str>); 5] = [
        (
            &[("CUDA_CACHE_PATH", "/cache/cuda"), ("HOME", "/home/worker")],
            Some("/cache/cuda"),
        ),
        (
            &[("HOME", "/home/worker")],
            Some("/home/worker/.nv/ComputeCache"),
        ),
        (
            &[("CUDA_CACHE_PATH", ""), ("HOME", "/home/worker")],
            Some("/home/worker/.nv/ComputeCache"),
        ),
        (
            &[
                ("CUDA_CACHE_DISABLE", "1"),
                ("CUDA_CACHE_PATH", "/cache/cuda"),
            ],
            None,
        ),
        (&[], None),
    ];
    for (vars, expected) in cases {
        assert_eq!(
            cuda_jit_cache_dir(&env(vars)),
            expected.map(std::path::PathBuf::from),
            "{vars:?}"
        );
    }

    let dir = TempDir::new().expect("temp dir");
    let writable = dir.path().join("cuda-cache");
    probe_writable_dir(&writable).expect("a fresh directory is writable");
    assert_eq!(
        std::fs::read_dir(&writable).expect("cache dir").count(),
        0,
        "the probe must not leave files behind"
    );
    let existing = writable.join(format!(".serviceradar-write-probe-{}", std::process::id()));
    std::fs::write(&existing, b"existing").expect("create existing cache file");
    probe_writable_dir(&writable).expect("probe shared cache");
    assert_eq!(
        std::fs::read(existing).expect("preserved file"),
        b"existing"
    );
    // A path under a regular file cannot be created, whoever runs the test.
    let blocker = dir.path().join("not-a-directory");
    std::fs::write(&blocker, b"").expect("write blocker file");
    assert!(probe_writable_dir(&blocker.join("cuda-cache")).is_err());
}

/// Delegates to the stub backend and records which towers ran.
pub(super) struct RecordingBackend {
    info: crate::InferenceBackendInfo,
    inner: DeterministicStubBackend,
    image_batches: std::sync::atomic::AtomicUsize,
    text_queries: std::sync::atomic::AtomicUsize,
}

impl RecordingBackend {
    pub(super) fn new(models: &ModelPinConfig, info: crate::InferenceBackendInfo) -> Self {
        Self {
            info,
            inner: DeterministicStubBackend::new(models.clone()),
            image_batches: Default::default(),
            text_queries: Default::default(),
        }
    }
}

impl InferenceBackend for RecordingBackend {
    fn detect_objects(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<crate::backend::RawDetection>, crate::errors::MediaWorkerError> {
        self.inner.detect_objects(frame, min_confidence)
    }

    fn encode_images(
        &self,
        frames: &[&RgbFrame],
    ) -> Result<Vec<Vec<f32>>, crate::errors::MediaWorkerError> {
        self.image_batches
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.inner.encode_images(frames)
    }

    fn encode_text(&self, query: &str) -> Result<Vec<f32>, crate::errors::MediaWorkerError> {
        self.text_queries
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.inner.encode_text(query)
    }

    fn info(&self) -> crate::backend::InferenceBackendInfo {
        self.info.clone()
    }
}

#[test]
fn cpu_explicit_refuses_a_supplied_cuda_backend_before_warmup() {
    use std::sync::atomic::Ordering;
    let config = WorkerConfig::cpu_explicit_default();
    let info = crate::InferenceBackendInfo::new(
        InferenceBackendKind::Candle,
        "cuda:0",
        config.models().embedding_dim(),
        "synthetic",
        false,
    );
    let backend = Arc::new(RecordingBackend::new(config.models(), info));
    let probe = StaticProbe(GpuEnvironmentObservation::no_gpu());
    let err = verify_startup_capabilities_with_backend(&config, &probe, backend.clone())
        .expect_err("CUDA under cpu_explicit");
    assert!(err.to_string().contains("cpu_explicit"));
    assert_eq!(backend.image_batches.load(Ordering::SeqCst), 0);
    assert_eq!(backend.text_queries.load(Ordering::SeqCst), 0);
}

#[test]
fn admission_refuses_mismatched_precision_before_either_warmup() {
    use std::sync::atomic::Ordering;

    let probe = StaticProbe(GpuEnvironmentObservation::new(
        1,
        false,
        false,
        None,
        Some(24_576),
        OrtRuntimeProbeResult::synthetic("test", true, false),
    ));
    for (provider, device, requested, active) in [
        ("cpu_explicit", "cpu", "auto", InferencePrecision::F16),
        ("cuda", "cuda:0", "auto", InferencePrecision::F32),
        ("cpu_explicit", "cpu", "f16", InferencePrecision::F32),
        ("cuda", "cuda:0", "f32", InferencePrecision::F16),
    ] {
        let config = CliArgs::try_parse_from([
            "serviceradar-media-worker",
            "--execution-provider",
            provider,
            "--dtype",
            requested,
        ])
        .expect("parse requested precision")
        .into_worker_config()
        .expect("worker config");
        let info = crate::InferenceBackendInfo::new(
            InferenceBackendKind::Candle,
            device,
            config.models().embedding_dim(),
            "synthetic",
            false,
        )
        .with_dtype(active);
        let backend = Arc::new(RecordingBackend::new(config.models(), info));
        let err = verify_startup_capabilities_with_backend(&config, &probe, backend.clone())
            .expect_err("mismatched precision");
        assert!(err.to_string().contains("precision"));
        assert_eq!(backend.image_batches.load(Ordering::SeqCst), 0);
        assert_eq!(backend.text_queries.load(Ordering::SeqCst), 0);
    }
}

#[test]
fn startup_admission_runs_image_and_text_warmup_before_reporting_ready() {
    // Readiness (and therefore job claims and text-embedding RPCs, which start only
    // after admission) must wait for both towers to have run once: on CUDA that first
    // pass is where the PTX JIT compile happens.
    let config = WorkerConfig::cpu_explicit_default().with_backend_kind(InferenceBackendKind::Stub);
    let info = build_inference_backend(&config).expect("CPU stub").info();
    let backend = Arc::new(RecordingBackend::new(config.models(), info));
    let probe = StaticProbe(GpuEnvironmentObservation::no_gpu());
    let manifest = verify_startup_capabilities_with_backend(
        &config,
        &probe,
        Arc::clone(&backend) as Arc<dyn InferenceBackend>,
    )
    .expect("startup admission");
    assert_eq!(manifest.status(), "ready");
    assert!(
        backend
            .image_batches
            .load(std::sync::atomic::Ordering::SeqCst)
            >= 1
    );
    assert!(
        backend
            .text_queries
            .load(std::sync::atomic::Ordering::SeqCst)
            >= 1
    );
}
