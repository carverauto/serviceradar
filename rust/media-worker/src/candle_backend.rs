//! Live pure-Rust HuggingFace `candle` inference backend (`.safetensors`, CPU + optional CUDA).
//!
//! Strictly loads model weights (`model.safetensors`, `config.json`, `tokenizer.json`,
//! and optional `detector.safetensors` / `detector_config.json`) from the local filesystem
//! (`MEDIA_WORKER_MODEL_DIR`) — never performs network downloads at runtime.
//!
//! The SigLIP towers run in the configured precision (`MEDIA_WORKER_DTYPE`): `f16` by
//! default on CUDA, `f32` on the CPU. Inputs are cast to the model dtype on the device
//! and outputs are cast back to `f32` before L2 normalisation, so every precision
//! produces vectors in the same space. The optional YOLOv8 detector always runs in `f32`.

use crate::backend::{
    InferenceBackend, InferenceBackendInfo, InferenceBackendKind, InferenceDevicePreference,
    InferencePrecision, RawDetection,
};
use crate::errors::MediaWorkerError;
use crate::tokenizer::PureRustTokenizer;
use crate::vision::RgbFrame;
use crate::yolo_v8::{YoloV8Config, YoloV8Detector};
use candle_core::{DType, Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::siglip;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use tracing::{info, warn};

const MAX_QUERY_CHARS: usize = 256;

/// Load-time options for [`CandleBackend::load`].
#[derive(Debug, Clone)]
pub struct CandleBackendOptions {
    device: InferenceDevicePreference,
    require_gpu: bool,
    embedding_dim: usize,
    precision: InferencePrecision,
    model_revision: Option<String>,
    detector_path: Option<PathBuf>,
    preprocess_threads: usize,
}

impl CandleBackendOptions {
    /// `require_gpu` is true for the `cuda` execution provider and false
    /// only for `cpu_explicit`. `embedding_dim` is the configured index width
    /// (`SERVICERADAR_MEDIA_WORKER_EMBEDDING_DIM`) the checkpoint must produce.
    pub fn new(device: InferenceDevicePreference, require_gpu: bool, embedding_dim: usize) -> Self {
        Self {
            device,
            require_gpu,
            embedding_dim,
            precision: InferencePrecision::Auto,
            model_revision: None,
            detector_path: None,
            preprocess_threads: 1,
        }
    }

    pub fn with_precision(mut self, precision: InferencePrecision) -> Self {
        self.precision = precision;
        self
    }

    pub fn with_model_revision(mut self, revision: impl Into<String>) -> Self {
        self.model_revision = Some(revision.into());
        self
    }

    pub fn with_detector_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.detector_path = Some(path.into());
        self
    }

    /// Upper bound on threads used to preprocess one image batch (minimum 1).
    pub(crate) fn with_preprocess_threads(mut self, threads: usize) -> Self {
        self.preprocess_threads = threads.max(1);
        self
    }
}

/// Preprocessing threads one batch may use: the cores available to the process,
/// shared across the `index_concurrency` jobs that can encode at the same time.
pub(crate) fn preprocess_thread_budget(index_concurrency: usize) -> usize {
    let cores = std::thread::available_parallelism().map_or(1, usize::from);
    (cores / index_concurrency.max(1)).max(1)
}

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
    precision: InferencePrecision,
    model_revision: String,
    preprocess_threads: usize,
}

// Compile-time guarantee that `CandleBackend` is thread-safe (`Send + Sync`).
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<CandleBackend>();
};

impl CandleBackend {
    /// Loads a SigLIP model (and optional YOLOv8 detector) strictly from `model_dir` on local disk.
    pub fn load(
        model_dir: &Path,
        options: &CandleBackendOptions,
    ) -> Result<Self, MediaWorkerError> {
        if !model_dir.exists() || !model_dir.is_dir() {
            return Err(MediaWorkerError::inference_failed(format!(
                "MEDIA_WORKER_MODEL_DIR '{}' does not exist or is not a directory",
                model_dir.display()
            )));
        }

        let (device, device_name) = resolve_candle_device(options.device, options.require_gpu)?;
        let precision = resolve_precision(options.precision, &device);
        if device.is_cuda() {
            report_cuda_jit_cache(&|key| std::env::var_os(key));
        } else if precision == InferencePrecision::F16 {
            warn!(
                "MEDIA_WORKER_DTYPE=f16 on the CPU is much slower than f32 and gains nothing; use it only for testing"
            );
        }

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
        verify_embedding_widths(&siglip_cfg, options.embedding_dim)?;

        let weights_path = resolve_siglip_weights_path(model_dir)?;
        let weights_bytes = std::fs::read(&weights_path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading SigLIP safetensors '{}': {err}",
                weights_path.display()
            ))
        })?;
        let vb =
            VarBuilder::from_buffered_safetensors(weights_bytes, candle_dtype(precision), &device)
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

        let detector =
            load_optional_detector(model_dir, options.detector_path.as_deref(), &device)?;

        let revision = options.model_revision.clone().unwrap_or_else(|| {
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
            precision,
            model_revision: revision,
            preprocess_threads: options.preprocess_threads,
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
        let batch_data = preprocess_siglip_batch(frames, image_size, self.preprocess_threads);

        let pixel_values =
            Tensor::from_vec(batch_data, (batch, 3, image_size, image_size), &self.device)
                .and_then(|t| t.to_dtype(candle_dtype(self.precision)))
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
        .with_dtype(self.precision)
    }
}

/// Resolves the Candle `Device` according to `MEDIA_WORKER_DEVICE` and the execution provider.
///
/// `require_gpu` is true for the `cuda` provider. The rules match startup
/// capability admission: a GPU provider never falls back to the CPU, and
/// `cpu_explicit` never silently picks up a GPU.
///
/// | device | GPU provider             | `cpu_explicit` |
/// |--------|--------------------------|----------------|
/// | `cpu`  | error                    | CPU            |
/// | `cuda` | CUDA, or error           | error          |
/// | `auto` | CUDA, or error           | CPU            |
pub fn resolve_candle_device(
    pref: InferenceDevicePreference,
    require_gpu: bool,
) -> Result<(Device, String), MediaWorkerError> {
    pref.validate_provider(require_gpu)?;
    if require_gpu {
        try_open_cuda_device()
    } else {
        Ok((Device::Cpu, "cpu".to_string()))
    }
}

/// Refuses a checkpoint whose towers do not emit the configured embedding width.
///
/// SigLIP's image embedding is the vision pooling head's output (`vision_config.hidden_size`)
/// and its text embedding is the text head's output (`text_config.hidden_size`, a square
/// projection). `siglip::Model::new` then checks every weight tensor against these sizes,
/// so a checkpoint that passes both checks really produces vectors of this width. A
/// mismatch would index vectors no query can ever match, so the worker must not start.
fn verify_embedding_widths(cfg: &siglip::Config, expected: usize) -> Result<(), MediaWorkerError> {
    let image_width = cfg.vision_config.hidden_size;
    let text_width = cfg.text_config.hidden_size;
    if image_width != expected || text_width != expected {
        return Err(MediaWorkerError::inference_failed(format!(
            "SigLIP checkpoint emits {image_width}-d image and {text_width}-d text embeddings, \
             but SERVICERADAR_MEDIA_WORKER_EMBEDDING_DIM is {expected}; refusing to start with \
             a checkpoint whose vectors cannot match the index"
        )));
    }
    Ok(())
}

/// Resolves `auto` to the precision for `device`: `f16` on CUDA, `f32` on the CPU.
pub(crate) fn resolve_precision(
    requested: InferencePrecision,
    device: &Device,
) -> InferencePrecision {
    match requested {
        InferencePrecision::Auto if device.is_cuda() => InferencePrecision::F16,
        InferencePrecision::Auto => InferencePrecision::F32,
        explicit => explicit,
    }
}

fn candle_dtype(precision: InferencePrecision) -> DType {
    match precision {
        InferencePrecision::F16 => DType::F16,
        InferencePrecision::F32 | InferencePrecision::Auto => DType::F32,
    }
}

fn try_open_cuda_device() -> Result<(Device, String), MediaWorkerError> {
    #[cfg(feature = "cuda")]
    {
        let dev = Device::new_cuda(0).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "CUDA device 0 unavailable in candle backend: {err}; the pod needs a GPU \
                 allocation (nvidia.com/gpu) and the NVIDIA container runtime; refusing \
                 silent CPU fallback"
            ))
        })?;
        Ok((dev, "cuda:0".to_string()))
    }
    #[cfg(not(feature = "cuda"))]
    {
        Err(MediaWorkerError::inference_failed(
            "CUDA device requested, but serviceradar-media-worker was built without the 'cuda' Cargo feature; use the serviceradar-media-worker-cuda image",
        ))
    }
}

/// Directory the CUDA driver uses for its PTX JIT cache: `CUDA_CACHE_PATH`, else
/// `$HOME/.nv/ComputeCache`. `None` when caching is disabled or no location is known.
pub(crate) fn cuda_jit_cache_dir(env: &dyn Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    let set = |key: &str| env(key).filter(|value| !value.is_empty());
    if set("CUDA_CACHE_DISABLE").is_some_and(|value| value != "0") {
        return None;
    }
    set("CUDA_CACHE_PATH")
        .map(PathBuf::from)
        .or_else(|| set("HOME").map(|home| PathBuf::from(home).join(".nv/ComputeCache")))
}

/// Creates `dir` if needed and proves a file can be written in it.
pub(crate) fn probe_writable_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let probe = dir.join(format!(
        ".serviceradar-write-probe-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::File::create_new(&probe)?;
    std::fs::remove_file(probe)
}

/// Logs whether the CUDA JIT cache can persist. Never fails startup: an unwritable
/// cache only means every start pays the PTX JIT compile again (seconds, not minutes).
fn report_cuda_jit_cache(env: &dyn Fn(&str) -> Option<OsString>) {
    match cuda_jit_cache_dir(env) {
        None => warn!(
            "CUDA JIT cache disabled or no location (set CUDA_CACHE_PATH to a writable volume); every start recompiles kernels"
        ),
        Some(dir) => match probe_writable_dir(&dir) {
            Ok(()) => info!(cuda_cache_path = %dir.display(), "CUDA JIT cache is writable"),
            Err(err) => warn!(
                cuda_cache_path = %dir.display(),
                error = %err,
                "CUDA JIT cache is not writable; every start recompiles kernels (mount a writable volume at CUDA_CACHE_PATH)"
            ),
        },
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

/// Preprocesses `frames` into one contiguous NCHW buffer, splitting the batch across
/// at most `max_threads` scoped threads (the calling thread included). Each image
/// owns a disjoint slice and is computed by the same function, so the output is
/// identical for every thread count.
pub(crate) fn preprocess_siglip_batch(
    frames: &[&RgbFrame],
    target: usize,
    max_threads: usize,
) -> Vec<f32> {
    let per_image = 3 * target * target;
    let mut out = vec![0.0f32; frames.len() * per_image];
    if per_image == 0 || frames.is_empty() {
        return out;
    }
    let workers = max_threads.clamp(1, frames.len());
    let images_per_worker = frames.len().div_ceil(workers);
    let process = |group: &[&RgbFrame], slots: &mut [f32]| {
        for (frame, slot) in group.iter().zip(slots.chunks_mut(per_image)) {
            preprocess_siglip_rgb_into(frame, target, slot);
        }
    };

    std::thread::scope(|scope| {
        let mut groups = frames
            .chunks(images_per_worker)
            .zip(out.chunks_mut(images_per_worker * per_image));
        let first = groups.next();
        for (group, slots) in groups {
            let spawned = std::thread::Builder::new()
                .name("siglip-preprocess".to_string())
                .spawn_scoped(scope, move || process(group, slots));
            if let Err(err) = spawned {
                // The closure (and its slice) is dropped with the error; redo this
                // group inline rather than fail the batch.
                warn!(error = %err, "could not spawn a preprocessing thread; continuing inline");
                return Err(());
            }
        }
        if let Some((group, slots)) = first {
            process(group, slots);
        }
        Ok(())
    })
    .unwrap_or_else(|()| {
        // A spawn failed after some groups were handed out: recompute everything on
        // this thread so no slot is left unwritten.
        for (frame, slot) in frames.iter().zip(out.chunks_mut(per_image)) {
            preprocess_siglip_rgb_into(frame, target, slot);
        }
    });
    out
}

/// Bilinearly resizes `frame` to `target x target` and writes CHW `[-1.0, 1.0]`
/// normalized floats into `out` (`3 * target * target` values).
fn preprocess_siglip_rgb_into(frame: &RgbFrame, target: usize, out: &mut [f32]) {
    let plane = target * target;
    debug_assert_eq!(out.len(), 3 * plane);

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
                out[c * plane + idx] = (pixel / 127.5) - 1.0;
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
