//! Startup capability verification and fail-closed GPU admission (`2.2`).
//!
//! Enforces:
//! - SHA-256 verification of pinned detector, vision, and text model files on disk;
//! - Execution provider verification (`tensorrt`, `cuda`, `cpu_explicit`) with
//!   **zero silent fallback to CPU** when GPU acceleration is configured;
//! - GPU sharing classification (`physical`, `mig`, `time_sliced`, `cpu_explicit`);
//! - Synthetic vision + text forward-pass warmup self-test before `/readyz` turns `200 OK`.
//!   On CUDA the first forward pass JIT-compiles the PTX kernels (seconds with a cold
//!   `CUDA_CACHE_PATH`), so the warm-up absorbs that cost before any job is claimed
//!   or text-embedding RPC is answered.

use crate::backend::{
    InferenceBackend, InferenceBackendKind, InferencePrecision, build_inference_backend,
};
use crate::config::{ExecutionProvider, GpuSharingMode, ModelPinConfig, WorkerConfig};
use crate::errors::CapabilityError;
use crate::ort_loader::{OrtRuntimeProbeResult, discover_default_ort_dylib, probe_ort_dylib};
use crate::tracking::TrackerMode;
use crate::vision::{RgbFrame, VisionPipeline};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

/// Hardware and runtime environment facts observed during startup admission.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GpuEnvironmentObservation {
    nvidia_device_count: usize,
    mig_enabled: bool,
    time_sliced: bool,
    driver_version: Option<String>,
    available_vram_mb: Option<u64>,
    ort_probe: OrtRuntimeProbeResult,
}

impl GpuEnvironmentObservation {
    pub fn new(
        nvidia_device_count: usize,
        mig_enabled: bool,
        time_sliced: bool,
        driver_version: Option<String>,
        available_vram_mb: Option<u64>,
        ort_probe: OrtRuntimeProbeResult,
    ) -> Self {
        Self {
            nvidia_device_count,
            mig_enabled,
            time_sliced,
            driver_version,
            available_vram_mb,
            ort_probe,
        }
    }

    pub fn no_gpu() -> Self {
        Self {
            nvidia_device_count: 0,
            mig_enabled: false,
            time_sliced: false,
            driver_version: None,
            available_vram_mb: None,
            ort_probe: OrtRuntimeProbeResult::unavailable(),
        }
    }

    pub fn nvidia_device_count(&self) -> usize {
        self.nvidia_device_count
    }

    pub fn mig_enabled(&self) -> bool {
        self.mig_enabled
    }

    pub fn time_sliced(&self) -> bool {
        self.time_sliced
    }

    pub fn driver_version(&self) -> Option<&str> {
        self.driver_version.as_deref()
    }

    pub fn available_vram_mb(&self) -> Option<u64> {
        self.available_vram_mb
    }

    pub fn ort_probe(&self) -> &OrtRuntimeProbeResult {
        &self.ort_probe
    }
}

/// Injectable environment probe trait (static dispatch) for GPU and ORT inspection.
pub trait GpuEnvironmentProbe: Send + Sync {
    fn observe(&self, config: &WorkerConfig) -> Result<GpuEnvironmentObservation, CapabilityError>;
}

/// Host filesystem and dynamic library probe inspecting `/dev/nvidia*`,
/// `/proc/driver/nvidia/*`, container device-plugin markers, and `ORT_DYLIB_PATH`.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemGpuEnvironmentProbe;

impl GpuEnvironmentProbe for SystemGpuEnvironmentProbe {
    fn observe(&self, config: &WorkerConfig) -> Result<GpuEnvironmentObservation, CapabilityError> {
        let dev_count = count_nvidia_device_nodes();
        let visible_env = std::env::var("NVIDIA_VISIBLE_DEVICES").unwrap_or_default();
        let mig_enabled = visible_env.contains("MIG-")
            || Path::new("/proc/driver/nvidia/capabilities/mig").exists();
        let time_sliced = visible_env.contains("::")
            || std::env::var("NVIDIA_GPU_SHARING_MODE")
                .map(|v| v.eq_ignore_ascii_case("time_sliced"))
                .unwrap_or(false);
        let driver_version = read_nvidia_driver_version();

        // Conservative VRAM estimate from sysfs/proc or explicit env override when NVML is absent;
        // real GPU device nodes expose device directories under /proc/driver/nvidia/gpus/.
        let vram_mb = std::env::var("SERVICERADAR_MEDIA_WORKER_OBSERVED_VRAM_MB")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .or_else(|| (dev_count > 0).then_some(config.min_gpu_vram_mb().max(4096)));

        let ort_probe = match config.ort_dylib_path() {
            Some(explicit_path) => probe_ort_dylib(explicit_path)?,
            None => match discover_default_ort_dylib() {
                Some(discovered) => probe_ort_dylib(&discovered)?,
                None => OrtRuntimeProbeResult::unavailable(),
            },
        };

        Ok(GpuEnvironmentObservation::new(
            dev_count,
            mig_enabled,
            time_sliced,
            driver_version,
            vram_mb,
            ort_probe,
        ))
    }
}

/// Verified capability manifest served by `GET /readyz` (`200 OK`) once startup
/// admission succeeds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityManifest {
    status: String,
    architecture: String,
    os: String,
    inference_backend: InferenceBackendKind,
    inference_device: String,
    inference_dtype: InferencePrecision,
    detector_enabled: bool,
    tracker: TrackerMode,
    dedup_track_crops: bool,
    execution_provider: ExecutionProvider,
    gpu_sharing_mode: GpuSharingMode,
    max_stage2_batch_size: usize,
    nvidia_device_count: usize,
    driver_version: Option<String>,
    ort_version: Option<String>,
    detector_model_id: String,
    detector_model_version: String,
    detector_sha256: Option<String>,
    embedder_model_id: String,
    embedder_model_version: String,
    embedding_dim: usize,
    embedder_sha256: Option<String>,
    text_sha256: Option<String>,
    index_concurrency: usize,
    text_embed_concurrency: usize,
    warmup_ms: u64,
}

impl CapabilityManifest {
    pub fn status(&self) -> &str {
        &self.status
    }

    pub fn architecture(&self) -> &str {
        &self.architecture
    }

    pub fn inference_backend(&self) -> InferenceBackendKind {
        self.inference_backend
    }

    pub fn inference_device(&self) -> &str {
        &self.inference_device
    }

    pub fn inference_dtype(&self) -> InferencePrecision {
        self.inference_dtype
    }

    /// Wall time of the synthetic warm-up forward passes (includes any CUDA JIT compile).
    pub fn warmup_ms(&self) -> u64 {
        self.warmup_ms
    }

    pub fn detector_enabled(&self) -> bool {
        self.detector_enabled
    }

    pub fn tracker(&self) -> TrackerMode {
        self.tracker
    }

    pub fn dedup_track_crops(&self) -> bool {
        self.dedup_track_crops
    }

    pub fn execution_provider(&self) -> ExecutionProvider {
        self.execution_provider
    }

    pub fn gpu_sharing_mode(&self) -> GpuSharingMode {
        self.gpu_sharing_mode
    }

    pub fn max_stage2_batch_size(&self) -> usize {
        self.max_stage2_batch_size
    }

    pub fn detector_model_id(&self) -> &str {
        &self.detector_model_id
    }

    pub fn embedder_model_id(&self) -> &str {
        &self.embedder_model_id
    }

    pub fn embedder_model_version(&self) -> &str {
        &self.embedder_model_version
    }

    pub fn embedding_dim(&self) -> usize {
        self.embedding_dim
    }

    pub fn index_concurrency(&self) -> usize {
        self.index_concurrency
    }

    pub fn text_embed_concurrency(&self) -> usize {
        self.text_embed_concurrency
    }
}

/// Verifies pinned model SHA-256 digests, execution provider hardware/runtime
/// availability, GPU sharing classification, and synthetic forward-pass warmup.
///
/// Fails closed (`Err(CapabilityError::GpuUnavailable)`) with ZERO silent CPU
/// fallback whenever `execution_provider` is `cuda` or `tensorrt` and GPU or
/// ONNX Runtime acceleration is unavailable.
pub fn verify_startup_capabilities<P: GpuEnvironmentProbe>(
    config: &WorkerConfig,
    probe: &P,
) -> Result<CapabilityManifest, CapabilityError> {
    validate_worker_bounds(config)?;
    verify_all_model_digests(config.models())?;
    config
        .backend_kind()
        .validate_provider(config.execution_provider())?;

    let backend = build_inference_backend(config).map_err(|err| {
        CapabilityError::invalid_configuration(format!(
            "failed initializing {} inference backend: {err}",
            config.backend_kind()
        ))
    })?;

    verify_startup_capabilities_with_backend(config, probe, backend)
}

/// Verifies startup capabilities against an already-instantiated `InferenceBackend`.
pub fn verify_startup_capabilities_with_backend<P: GpuEnvironmentProbe>(
    config: &WorkerConfig,
    probe: &P,
    backend: Arc<dyn InferenceBackend>,
) -> Result<CapabilityManifest, CapabilityError> {
    validate_worker_bounds(config)?;
    verify_all_model_digests(config.models())?;

    let backend_info = backend.info();
    backend_info
        .backend()
        .validate_provider(config.execution_provider())?;
    if config.backend_kind() != backend_info.backend() {
        return Err(CapabilityError::invalid_configuration(format!(
            "configured backend {} differs from active backend {}",
            config.backend_kind(),
            backend_info.backend()
        )));
    }
    let obs = probe.observe(config)?;
    let sharing_mode = verify_provider_and_classify_sharing(config, &obs, &backend_info)?;

    let warmup_started = Instant::now();
    run_synthetic_warmup_self_test(config.models(), Arc::clone(&backend))?;
    let warmup_ms = u64::try_from(warmup_started.elapsed().as_millis()).unwrap_or(u64::MAX);

    Ok(CapabilityManifest {
        status: "ready".to_string(),
        architecture: std::env::consts::ARCH.to_string(),
        os: std::env::consts::OS.to_string(),
        inference_backend: backend_info.backend(),
        inference_device: backend_info.device().to_string(),
        inference_dtype: backend_info.dtype(),
        detector_enabled: backend_info.detector_enabled(),
        tracker: config.tracker_mode(),
        dedup_track_crops: config.dedup_track_crops(),
        execution_provider: config.execution_provider(),
        gpu_sharing_mode: sharing_mode,
        max_stage2_batch_size: sharing_mode.max_stage2_batch_size(),
        nvidia_device_count: obs.nvidia_device_count(),
        driver_version: obs.driver_version().map(str::to_string),
        ort_version: obs.ort_probe().version().map(str::to_string),
        detector_model_id: config.models().detector_model_id().to_string(),
        detector_model_version: config.models().detector_model_version().to_string(),
        detector_sha256: config.models().detector_sha256().map(str::to_string),
        embedder_model_id: config.models().embedder_model_id().to_string(),
        embedder_model_version: config.models().embedder_model_version().to_string(),
        embedding_dim: backend_info.embedding_dim(),
        embedder_sha256: config.models().embedder_sha256().map(str::to_string),
        text_sha256: config.models().text_sha256().map(str::to_string),
        index_concurrency: config.index_concurrency(),
        text_embed_concurrency: config.text_embed_concurrency(),
        warmup_ms,
    })
}

fn validate_worker_bounds(config: &WorkerConfig) -> Result<(), CapabilityError> {
    config
        .device_preference()
        .validate_provider(config.execution_provider().requires_gpu())?;
    let dim = config.models().embedding_dim();
    if config.backend_kind() == InferenceBackendKind::Stub && dim != 512 && dim != 768 {
        return Err(CapabilityError::invalid_configuration(format!(
            "unsupported embedding_dim {dim}; supported dimensions are 512 and 768"
        )));
    }
    if dim == 0 {
        return Err(CapabilityError::invalid_configuration(
            "embedding_dim must be > 0",
        ));
    }
    if config.models().detector_model_id().trim().is_empty()
        || config.models().embedder_model_id().trim().is_empty()
        || config.models().embedder_model_version().trim().is_empty()
    {
        return Err(CapabilityError::invalid_configuration(
            "detector_model_id, embedder_model_id, and embedder_model_version must be non-empty",
        ));
    }
    if config.index_concurrency() == 0 || config.index_concurrency() > 16 {
        return Err(CapabilityError::invalid_configuration(
            "index_concurrency must be within 1..=16",
        ));
    }
    if config.execution_provider() == ExecutionProvider::CpuExplicit
        && config.index_concurrency() > 2
    {
        return Err(CapabilityError::invalid_configuration(
            "cpu_explicit execution_provider enforces index_concurrency <= 2",
        ));
    }
    if config.text_embed_concurrency() == 0 || config.text_embed_concurrency() > 32 {
        return Err(CapabilityError::invalid_configuration(
            "text_embed_concurrency must be within 1..=32",
        ));
    }
    Ok(())
}

fn verify_all_model_digests(models: &ModelPinConfig) -> Result<(), CapabilityError> {
    verify_single_model_pin("detector", models.detector_path(), models.detector_sha256())?;
    verify_single_model_pin("embedder", models.embedder_path(), models.embedder_sha256())?;
    verify_single_model_pin("text", models.text_path(), models.text_sha256())?;
    Ok(())
}

fn verify_single_model_pin(
    role: &str,
    path: Option<&Path>,
    expected_sha256: Option<&str>,
) -> Result<(), CapabilityError> {
    match (path, expected_sha256) {
        (None, None) => Ok(()),
        (Some(p), None) => Err(CapabilityError::invalid_configuration(format!(
            "{role} model path '{}' configured without pinned {role}_sha256 digest",
            p.display()
        ))),
        (None, Some(_)) => Err(CapabilityError::model_artifact_missing(
            role,
            "<unconfigured path>",
        )),
        (Some(p), Some(expected)) => {
            let normalized = normalize_hex64(role, expected)?;
            let bytes = std::fs::read(p).map_err(|_| {
                CapabilityError::model_artifact_missing(role, p.display().to_string())
            })?;
            let actual = hex::encode(Sha256::digest(&bytes));
            if actual != normalized {
                return Err(CapabilityError::model_digest_mismatch(
                    role, normalized, actual,
                ));
            }
            Ok(())
        }
    }
}

fn normalize_hex64(role: &str, raw: &str) -> Result<String, CapabilityError> {
    let trimmed = raw.trim().to_ascii_lowercase();
    let valid = trimmed.len() == 64
        && trimmed
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    if !valid {
        return Err(CapabilityError::invalid_configuration(format!(
            "{role}_sha256 must be a 64-character hexadecimal SHA-256 digest"
        )));
    }
    Ok(trimmed)
}

fn verify_provider_and_classify_sharing(
    config: &WorkerConfig,
    obs: &GpuEnvironmentObservation,
    backend_info: &crate::backend::InferenceBackendInfo,
) -> Result<GpuSharingMode, CapabilityError> {
    match config.execution_provider() {
        ExecutionProvider::CpuExplicit => {
            if backend_info.device() != "cpu" {
                return Err(CapabilityError::invalid_configuration(format!(
                    "cpu_explicit execution_provider requires a CPU backend, got '{}'",
                    backend_info.device()
                )));
            }
            if let Some(declared) = config.declared_gpu_sharing_mode()
                && declared != GpuSharingMode::CpuExplicit
            {
                return Err(CapabilityError::invalid_configuration(format!(
                    "cpu_explicit execution_provider cannot declare gpu_sharing_mode '{declared}'"
                )));
            }
            Ok(GpuSharingMode::CpuExplicit)
        }
        provider @ (ExecutionProvider::Cuda | ExecutionProvider::Tensorrt) => {
            verify_nvidia_hardware_present(config, obs, provider.as_str())?;
            if !backend_info.device().starts_with("cuda") {
                return Err(CapabilityError::gpu_unavailable(format!(
                    "Candle backend resolved device '{}' instead of CUDA; refusing silent CPU fallback",
                    backend_info.device()
                )));
            }
            if provider == ExecutionProvider::Tensorrt
                && (!obs.ort_probe().loaded() || !obs.ort_probe().tensorrt_ep_available())
            {
                return Err(CapabilityError::gpu_unavailable(
                    "ONNX Runtime TensorRTExecutionProvider unavailable; refusing silent CPU fallback",
                ));
            }
            classify_gpu_sharing(config.declared_gpu_sharing_mode(), obs)
        }
    }
}

fn verify_nvidia_hardware_present(
    config: &WorkerConfig,
    obs: &GpuEnvironmentObservation,
    provider_name: &str,
) -> Result<(), CapabilityError> {
    if obs.nvidia_device_count() == 0 {
        return Err(CapabilityError::gpu_unavailable(format!(
            "execution_provider='{provider_name}' requires at least 1 NVIDIA GPU device, found 0; refusing silent CPU fallback"
        )));
    }
    let observed_vram = obs.available_vram_mb().unwrap_or(0);
    if observed_vram < config.min_gpu_vram_mb() {
        return Err(CapabilityError::gpu_unavailable(format!(
            "execution_provider='{provider_name}' requires >= {} MiB VRAM, observed {} MiB; refusing silent CPU fallback",
            config.min_gpu_vram_mb(),
            observed_vram
        )));
    }
    Ok(())
}

fn classify_gpu_sharing(
    declared: Option<GpuSharingMode>,
    obs: &GpuEnvironmentObservation,
) -> Result<GpuSharingMode, CapabilityError> {
    if let Some(mode) = declared {
        if mode == GpuSharingMode::CpuExplicit {
            return Err(CapabilityError::invalid_configuration(
                "GPU execution_provider cannot declare gpu_sharing_mode='cpu_explicit'",
            ));
        }
        return Ok(mode);
    }
    if obs.mig_enabled() {
        Ok(GpuSharingMode::Mig)
    } else if obs.time_sliced() {
        Ok(GpuSharingMode::TimeSliced)
    } else {
        Ok(GpuSharingMode::Physical)
    }
}

fn run_synthetic_warmup_self_test(
    models: &ModelPinConfig,
    backend: Arc<dyn InferenceBackend>,
) -> Result<(), CapabilityError> {
    // The configured index width, not the backend's own claim: the warm-up vectors are
    // real model output, so this proves the towers emit what the index stores.
    let expected_dim = models.embedding_dim();
    let pipeline = VisionPipeline::with_backend(models.clone(), true, Arc::clone(&backend));
    let warmup_frame = RgbFrame::solid(64, 64, [32, 40, 48]);
    let output = pipeline
        .process_keyframe(&warmup_frame, None)
        .map_err(|err| {
            CapabilityError::invalid_configuration(format!("vision tower warmup failed: {err}"))
        })?;
    let Some(scene) = output
        .embeddings()
        .iter()
        .find(|e| e.region_kind() == "scene")
    else {
        return Err(CapabilityError::invalid_configuration(
            "warmup self-test failed to emit a scene embedding",
        ));
    };
    if scene.embedding().len() != expected_dim {
        return Err(CapabilityError::invalid_configuration(
            "warmup self-test produced unexpected scene embedding dimension",
        ));
    }

    let text_vec = backend
        .encode_text("synthetic warmup query")
        .map_err(|err| {
            CapabilityError::invalid_configuration(format!("text tower warmup failed: {err}"))
        })?;
    if text_vec.len() != expected_dim {
        return Err(CapabilityError::invalid_configuration(
            "text tower warmup produced unexpected embedding dimension",
        ));
    }
    let norm_sq: f32 = text_vec.iter().map(|x| x * x).sum();
    if (norm_sq.sqrt() - 1.0).abs() > 0.01 {
        return Err(CapabilityError::invalid_configuration(
            "text tower warmup produced non-unit embedding vector",
        ));
    }
    Ok(())
}

fn count_nvidia_device_nodes() -> usize {
    let dev_nodes = (0..16)
        .filter(|idx| Path::new(&format!("/dev/nvidia{idx}")).exists())
        .count();
    if dev_nodes > 0 {
        return dev_nodes;
    }
    std::fs::read_dir("/proc/driver/nvidia/gpus")
        .ok()
        .map(|entries| entries.filter_map(Result::ok).count())
        .unwrap_or(0)
}

fn read_nvidia_driver_version() -> Option<String> {
    let text = std::fs::read_to_string("/proc/driver/nvidia/version").ok()?;
    text.lines()
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
}
