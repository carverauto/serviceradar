//! Live pure-Rust HuggingFace `candle` inference backend (`.safetensors`, CPU + optional CUDA).
//!
//! Strictly loads model weights (`model.safetensors`, `config.json`, `tokenizer.json`,
//! and optional `detector.safetensors` / `detector_config.json`) from the local filesystem
//! (`MEDIA_WORKER_MODEL_DIR`) — never performs network downloads at runtime.

use crate::backend::{
    InferenceBackend, InferenceBackendInfo, InferenceBackendKind, InferenceDevicePreference,
    RawDetection,
};
use crate::errors::MediaWorkerError;
use crate::tokenizer::PureRustTokenizer;
use crate::vision::RgbFrame;
use crate::yolo_v8::{YoloV8Config, YoloV8Detector};
use candle_core::{DType, Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::siglip;
use std::path::{Path, PathBuf};

const MAX_QUERY_CHARS: usize = 256;

/// Live pure-Rust `candle` inference backend running SigLIP vision + text towers
/// and an optional YOLOv8 Stage 1 detector.
#[derive(Debug)]
pub struct CandleBackend {
    siglip: siglip::Model,
    siglip_cfg: siglip::Config,
    tokenizer: PureRustTokenizer,
    detector: Option<YoloV8Detector>,
    device: Device,
    device_name: String,
    model_revision: String,
}

// Compile-time guarantee that `CandleBackend` is thread-safe (`Send + Sync`).
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<CandleBackend>();
};

impl CandleBackend {
    /// Loads a SigLIP model (and optional YOLOv8 detector) strictly from `model_dir` on local disk.
    pub fn load_from_dir(
        model_dir: &Path,
        device_pref: InferenceDevicePreference,
        require_gpu: bool,
        model_revision: Option<String>,
        explicit_detector_path: Option<&Path>,
    ) -> Result<Self, MediaWorkerError> {
        if !model_dir.exists() || !model_dir.is_dir() {
            return Err(MediaWorkerError::inference_failed(format!(
                "MEDIA_WORKER_MODEL_DIR '{}' does not exist or is not a directory",
                model_dir.display()
            )));
        }

        let (device, device_name) = resolve_candle_device(device_pref, require_gpu)?;

        let config_path = model_dir.join("config.json");
        let config_bytes = std::fs::read(&config_path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading SigLIP config '{}': {err}",
                config_path.display()
            ))
        })?;
        let siglip_cfg: siglip::Config = serde_json::from_slice(&config_bytes).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed parsing SigLIP config '{}': {err}",
                config_path.display()
            ))
        })?;

        if siglip_cfg.vision_config.hidden_size == 0
            || siglip_cfg.vision_config.image_size == 0
            || siglip_cfg.vision_config.patch_size == 0
        {
            return Err(MediaWorkerError::inference_failed(
                "invalid SigLIP vision_config: hidden_size, image_size, and patch_size must be > 0",
            ));
        }

        let weights_path = resolve_siglip_weights_path(model_dir)?;
        let weights_bytes = std::fs::read(&weights_path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading SigLIP safetensors '{}': {err}",
                weights_path.display()
            ))
        })?;
        let vb = VarBuilder::from_buffered_safetensors(weights_bytes, DType::F32, &device)
            .map_err(|err| {
                MediaWorkerError::inference_failed(format!(
                    "failed loading SigLIP safetensors '{}': {err}",
                    weights_path.display()
                ))
            })?;
        let siglip = siglip::Model::new(&siglip_cfg, vb).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed constructing SigLIP model from '{}': {err}",
                weights_path.display()
            ))
        })?;

        let tokenizer_path = model_dir.join("tokenizer.json");
        let tokenizer = PureRustTokenizer::from_file(&tokenizer_path)?;

        let detector = load_optional_detector(model_dir, explicit_detector_path, &device)?;

        let revision = model_revision.unwrap_or_else(|| {
            model_dir
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("siglip-local")
                .to_string()
        });

        Ok(Self {
            siglip,
            siglip_cfg,
            tokenizer,
            detector,
            device,
            device_name,
            model_revision: revision,
        })
    }

    pub fn embedding_dim(&self) -> usize {
        self.siglip_cfg.vision_config.hidden_size
    }

    pub fn image_size(&self) -> usize {
        self.siglip_cfg.vision_config.image_size
    }

    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    pub fn detector_enabled(&self) -> bool {
        self.detector.is_some()
    }
}

impl InferenceBackend for CandleBackend {
    fn detect_objects(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<RawDetection>, MediaWorkerError> {
        match &self.detector {
            Some(det) => det.detect(frame, min_confidence),
            // Clean fallback to scene-only indexing when detector weights are not configured.
            None => Ok(Vec::new()),
        }
    }

    fn encode_images(&self, frames: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
        if frames.is_empty() {
            return Ok(Vec::new());
        }

        let image_size = self.siglip_cfg.vision_config.image_size;
        let batch = frames.len();
        let per_image = 3 * image_size * image_size;
        let mut batch_data = Vec::with_capacity(batch * per_image);
        for frame in frames {
            preprocess_siglip_rgb_into(frame, image_size, &mut batch_data);
        }

        let pixel_values =
            Tensor::from_vec(batch_data, (batch, 3, image_size, image_size), &self.device)
                .map_err(|err| {
                    MediaWorkerError::inference_failed(format!(
                        "failed creating image tensor: {err}"
                    ))
                })?;

        let features = self
            .siglip
            .get_image_features(&pixel_values)
            .and_then(|t| t.to_dtype(DType::F32))
            .and_then(|t| t.to_device(&Device::Cpu))
            .map_err(|err| {
                MediaWorkerError::inference_failed(format!("SigLIP vision forward failed: {err}"))
            })?;

        let rows = features.to_vec2::<f32>().map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed extracting SigLIP image embeddings: {err}"
            ))
        })?;

        rows.into_iter().map(l2_normalize_checked).collect()
    }

    fn encode_text(&self, query: &str) -> Result<Vec<f32>, MediaWorkerError> {
        let trimmed = query.trim();
        let char_count = trimmed.chars().count();
        if char_count == 0 || char_count > MAX_QUERY_CHARS {
            return Err(MediaWorkerError::invalid_text_embed_request(format!(
                "query must be 1..={MAX_QUERY_CHARS} characters after trimming"
            )));
        }

        let text_cfg = &self.siglip_cfg.text_config;
        let token_ids = self.tokenizer.encode_padded(
            trimmed,
            text_cfg.max_position_embeddings,
            text_cfg.pad_token_id,
            text_cfg.eos_token_id,
            text_cfg.vocab_size,
        )?;
        let seq_len = token_ids.len();
        let input_ids = Tensor::from_vec(token_ids, (1, seq_len), &self.device).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed creating text token tensor: {err}"))
        })?;

        let features = self
            .siglip
            .get_text_features(&input_ids)
            .and_then(|t| t.to_dtype(DType::F32))
            .and_then(|t| t.to_device(&Device::Cpu))
            .map_err(|err| {
                MediaWorkerError::inference_failed(format!("SigLIP text forward failed: {err}"))
            })?;

        let mut rows = features.to_vec2::<f32>().map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed extracting SigLIP text embedding: {err}"
            ))
        })?;
        let vec = rows.pop().ok_or_else(|| {
            MediaWorkerError::inference_failed("SigLIP text forward returned empty batch")
        })?;

        l2_normalize_checked(vec)
    }

    fn info(&self) -> InferenceBackendInfo {
        InferenceBackendInfo::new(
            InferenceBackendKind::Candle,
            self.device_name.clone(),
            self.siglip_cfg.vision_config.hidden_size,
            self.model_revision.clone(),
            self.detector.is_some(),
        )
    }
}

/// Resolves the Candle `Device` according to `MEDIA_WORKER_DEVICE` and GPU admission policy.
pub fn resolve_candle_device(
    pref: InferenceDevicePreference,
    require_gpu: bool,
) -> Result<(Device, String), MediaWorkerError> {
    match pref {
        InferenceDevicePreference::Cpu => {
            if require_gpu {
                return Err(MediaWorkerError::inference_failed(
                    "MEDIA_WORKER_DEVICE=cpu conflicts with GPU execution provider; refusing silent CPU fallback",
                ));
            }
            Ok((Device::Cpu, "cpu".to_string()))
        }
        InferenceDevicePreference::Cuda => try_open_cuda_device(),
        InferenceDevicePreference::Auto => match try_open_cuda_device() {
            Ok(cuda) => Ok(cuda),
            Err(cuda_err) => {
                if require_gpu {
                    Err(cuda_err)
                } else {
                    Ok((Device::Cpu, "cpu".to_string()))
                }
            }
        },
    }
}

fn try_open_cuda_device() -> Result<(Device, String), MediaWorkerError> {
    #[cfg(feature = "cuda")]
    {
        let dev = Device::new_cuda(0).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "CUDA device 0 unavailable in candle backend: {err}"
            ))
        })?;
        Ok((dev, "cuda:0".to_string()))
    }
    #[cfg(not(feature = "cuda"))]
    {
        Err(MediaWorkerError::inference_failed(
            "CUDA device requested, but serviceradar-media-worker was built without the 'cuda' Cargo feature",
        ))
    }
}

fn resolve_siglip_weights_path(model_dir: &Path) -> Result<PathBuf, MediaWorkerError> {
    let candidates = ["model.safetensors", "siglip.safetensors"];
    for name in candidates {
        let p = model_dir.join(name);
        if p.is_file() {
            return Ok(p);
        }
    }
    Err(MediaWorkerError::inference_failed(format!(
        "no SigLIP safetensors weights found in '{}' (expected 'model.safetensors' or 'siglip.safetensors')",
        model_dir.display()
    )))
}

fn load_optional_detector(
    model_dir: &Path,
    explicit_detector_path: Option<&Path>,
    device: &Device,
) -> Result<Option<YoloV8Detector>, MediaWorkerError> {
    let weights_path = if let Some(explicit) = explicit_detector_path {
        if explicit
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|ext| ext.eq_ignore_ascii_case("safetensors"))
        {
            Some(explicit.to_path_buf())
        } else {
            None
        }
    } else {
        ["detector.safetensors", "yolov8.safetensors"]
            .into_iter()
            .map(|name| model_dir.join(name))
            .find(|p| p.is_file())
    };

    let Some(weights_path) = weights_path else {
        return Ok(None);
    };

    let cfg_path = model_dir.join("detector_config.json");
    let cfg = if cfg_path.is_file() {
        let raw = std::fs::read(&cfg_path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading detector_config.json '{}': {err}",
                cfg_path.display()
            ))
        })?;
        serde_json::from_slice::<YoloV8Config>(&raw).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed parsing detector_config.json '{}': {err}",
                cfg_path.display()
            ))
        })?
    } else {
        YoloV8Config::default()
    };

    let detector = YoloV8Detector::load(&weights_path, cfg, device)?;
    Ok(Some(detector))
}

/// Bilinearly resizes `frame` to `target x target` and appends CHW `[-1.0, 1.0]` normalized floats.
fn preprocess_siglip_rgb_into(frame: &RgbFrame, target: usize, out: &mut Vec<f32>) {
    let plane = target * target;
    let base = out.len();
    out.resize(base + 3 * plane, 0.0f32);

    let sw = frame.width() as f32;
    let sh = frame.height() as f32;
    let t = target as f32;

    for dy in 0..target {
        let sy = ((dy as f32 + 0.5) * sh / t - 0.5).clamp(0.0, sh - 1.0);
        let y0 = sy.floor() as u32;
        let y1 = (y0 + 1).min(frame.height() - 1);
        let fy = sy - (y0 as f32);

        for dx in 0..target {
            let sx = ((dx as f32 + 0.5) * sw / t - 0.5).clamp(0.0, sw - 1.0);
            let x0 = sx.floor() as u32;
            let x1 = (x0 + 1).min(frame.width() - 1);
            let fx = sx - (x0 as f32);

            let p00 = frame.pixel_at(x0, y0);
            let p10 = frame.pixel_at(x1, y0);
            let p01 = frame.pixel_at(x0, y1);
            let p11 = frame.pixel_at(x1, y1);

            let idx = dy * target + dx;
            for c in 0..3 {
                let top = (p00[c] as f32) * (1.0 - fx) + (p10[c] as f32) * fx;
                let bot = (p01[c] as f32) * (1.0 - fx) + (p11[c] as f32) * fx;
                let pixel = top * (1.0 - fy) + bot * fy;
                // SigLIP image normalization: mean=0.5, std=0.5 -> [-1.0, 1.0]
                out[base + c * plane + idx] = (pixel / 127.5) - 1.0;
            }
        }
    }
}

fn l2_normalize_checked(mut vec: Vec<f32>) -> Result<Vec<f32>, MediaWorkerError> {
    if vec.is_empty() {
        return Err(MediaWorkerError::inference_failed(
            "model produced empty embedding vector",
        ));
    }
    if vec.iter().any(|v| !v.is_finite()) {
        return Err(MediaWorkerError::inference_failed(
            "model produced non-finite (NaN/Inf) embedding values",
        ));
    }
    let norm_sq: f32 = vec.iter().map(|v| v * v).sum();
    if norm_sq <= 1e-12 {
        return Err(MediaWorkerError::inference_failed(
            "model produced zero-norm embedding vector",
        ));
    }
    let inv = 1.0 / norm_sq.sqrt();
    for v in &mut vec {
        *v *= inv;
    }
    Ok(vec)
}
