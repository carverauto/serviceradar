//! Pluggable vision and text inference backend abstraction (`InferenceBackend`).
//!
//! Decouples `VisionPipeline`, `TextEmbedService`, and `VisualIndexProcessor` from
//! the concrete execution engine so both the deterministic reference stub
//! (`MEDIA_WORKER_BACKEND=stub`) and the live pure-Rust HuggingFace `candle`
//! backend (`MEDIA_WORKER_BACKEND=candle`) share one `Send + Sync` contract.

use crate::candle_backend::{CandleBackend, CandleBackendOptions, preprocess_thread_budget};
use crate::config::{ExecutionProvider, ModelPinConfig, WorkerConfig};
use crate::errors::{CapabilityError, MediaWorkerError};
use crate::vision::{
    ObjectClass, RgbFrame, classify_dominant_colors, detect_stub_objects, embed_query_text,
    encode_stub_visual_region,
};
use core::fmt::{self, Display, Formatter};
use core::str::FromStr;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// Active inference backend implementation kind (`MEDIA_WORKER_BACKEND`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InferenceBackendKind {
    Stub,
    Candle,
}

impl InferenceBackendKind {
    pub(crate) fn validate_provider(
        self,
        provider: ExecutionProvider,
    ) -> Result<(), CapabilityError> {
        if self == Self::Stub && provider.requires_gpu() {
            return Err(CapabilityError::gpu_unavailable(
                "MEDIA_WORKER_BACKEND=stub requires execution_provider=cpu_explicit",
            ));
        }
        if self == Self::Candle && provider == ExecutionProvider::Tensorrt {
            return Err(CapabilityError::gpu_unavailable(
                "Candle does not support the tensorrt execution provider",
            ));
        }
        Ok(())
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stub => "stub",
            Self::Candle => "candle",
        }
    }
}

impl Display for InferenceBackendKind {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for InferenceBackendKind {
    type Err = CapabilityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "stub" => Ok(Self::Stub),
            _ if s.trim().is_empty() || s.trim().eq_ignore_ascii_case("candle") => Ok(Self::Candle),
            other => Err(CapabilityError::invalid_configuration(format!(
                "unsupported MEDIA_WORKER_BACKEND '{other}'; expected 'candle' or 'stub'"
            ))),
        }
    }
}

/// Requested execution device policy (`MEDIA_WORKER_DEVICE=auto|cuda|cpu`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InferenceDevicePreference {
    Auto,
    Cuda,
    Cpu,
}

impl InferenceDevicePreference {
    pub(crate) fn validate_provider(self, require_gpu: bool) -> Result<(), CapabilityError> {
        match (self, require_gpu) {
            (Self::Cpu, true) => Err(CapabilityError::invalid_configuration(
                "MEDIA_WORKER_DEVICE=cpu conflicts with GPU execution provider",
            )),
            (Self::Cuda, false) => Err(CapabilityError::invalid_configuration(
                "MEDIA_WORKER_DEVICE=cuda conflicts with execution_provider=cpu_explicit",
            )),
            _ => Ok(()),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Cuda => "cuda",
            Self::Cpu => "cpu",
        }
    }
}

impl Display for InferenceDevicePreference {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for InferenceDevicePreference {
    type Err = CapabilityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" => Ok(Self::Auto),
            "cuda" | "gpu" => Ok(Self::Cuda),
            "cpu" => Ok(Self::Cpu),
            other => Err(CapabilityError::invalid_configuration(format!(
                "unsupported MEDIA_WORKER_DEVICE '{other}'; expected 'auto', 'cuda', or 'cpu'"
            ))),
        }
    }
}

/// Requested numeric precision for the SigLIP towers (`MEDIA_WORKER_DTYPE=auto|f32|f16`).
///
/// `auto` resolves to `f16` on a CUDA device and `f32` on the CPU. Embeddings are
/// always returned as L2-normalised `f32` in the same vector space, whatever the
/// compute precision, so the reported model identity does not depend on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InferencePrecision {
    Auto,
    F32,
    F16,
}

impl InferencePrecision {
    pub(crate) fn resolve(self, cuda: bool) -> Self {
        match self {
            Self::Auto if cuda => Self::F16,
            Self::Auto => Self::F32,
            explicit => explicit,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::F32 => "f32",
            Self::F16 => "f16",
        }
    }
}

impl Display for InferencePrecision {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for InferencePrecision {
    type Err = CapabilityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "auto" => Ok(Self::Auto),
            "f32" => Ok(Self::F32),
            "f16" => Ok(Self::F16),
            other => Err(CapabilityError::invalid_configuration(format!(
                "unsupported MEDIA_WORKER_DTYPE '{other}'; expected 'auto', 'f32', or 'f16'"
            ))),
        }
    }
}

/// Metadata describing an instantiated `InferenceBackend`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InferenceBackendInfo {
    backend: InferenceBackendKind,
    device: String,
    dtype: InferencePrecision,
    embedding_dim: usize,
    model_revision: String,
    detector_enabled: bool,
}

impl InferenceBackendInfo {
    pub fn new(
        backend: InferenceBackendKind,
        device: impl Into<String>,
        embedding_dim: usize,
        model_revision: impl Into<String>,
        detector_enabled: bool,
    ) -> Self {
        Self {
            backend,
            device: device.into(),
            dtype: InferencePrecision::F32,
            embedding_dim,
            model_revision: model_revision.into(),
            detector_enabled,
        }
    }

    /// Records the resolved compute precision (never `Auto`) of the embedding towers.
    pub fn with_dtype(mut self, dtype: InferencePrecision) -> Self {
        self.dtype = dtype;
        self
    }

    pub fn backend(&self) -> InferenceBackendKind {
        self.backend
    }

    pub fn device(&self) -> &str {
        &self.device
    }

    pub fn dtype(&self) -> InferencePrecision {
        self.dtype
    }

    pub fn embedding_dim(&self) -> usize {
        self.embedding_dim
    }

    pub fn model_revision(&self) -> &str {
        &self.model_revision
    }

    pub fn detector_enabled(&self) -> bool {
        self.detector_enabled
    }
}

/// Raw Stage 1 object detection returned by an `InferenceBackend` prior to
/// pipeline-level padding, dominant-color extraction, and NMS capping.
#[derive(Debug, Clone, PartialEq)]
pub struct RawDetection {
    object_class: ObjectClass,
    confidence: f32,
    bbox_norm: [f32; 4],
}

impl RawDetection {
    pub fn new(object_class: ObjectClass, confidence: f32, bbox_norm: [f32; 4]) -> Self {
        Self {
            object_class,
            confidence,
            bbox_norm,
        }
    }

    pub fn object_class(&self) -> ObjectClass {
        self.object_class
    }

    pub fn confidence(&self) -> f32 {
        self.confidence
    }

    pub fn bbox_norm(&self) -> [f32; 4] {
        self.bbox_norm
    }
}

/// Pluggable, thread-safe vision and text inference backend contract.
pub trait InferenceBackend: Send + Sync {
    /// Stage 1: detects surveillance subjects in `frame` above `min_confidence`.
    fn detect_objects(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<RawDetection>, MediaWorkerError>;

    /// Stage 2: encodes a batch of RGB frames into L2-normalized embedding vectors.
    fn encode_images(&self, frames: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError>;

    /// Encodes a natural-language search query into an L2-normalized embedding
    /// aligned in the same vector space as `encode_images`.
    fn encode_text(&self, query: &str) -> Result<Vec<f32>, MediaWorkerError>;

    /// Returns metadata describing the active backend, device, and model revision.
    fn info(&self) -> InferenceBackendInfo;

    /// Optional batch encoding hook with per-region Stage 1 annotations.
    ///
    /// Live neural backends (`CandleBackend`) use the default implementation which
    /// delegates directly to `encode_images`. The deterministic reference stub
    /// overrides this to preserve compositional `(class, color)` synthetic ranking.
    fn encode_annotated_images(
        &self,
        regions: &[(&RgbFrame, Option<ObjectClass>, &[String])],
    ) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
        let frames: Vec<&RgbFrame> = regions.iter().map(|(frame, _, _)| *frame).collect();
        self.encode_images(&frames)
    }
}

/// Deterministic CPU reference backend used for CI/smoke tests and `MEDIA_WORKER_BACKEND=stub`.
#[derive(Debug, Clone)]
pub struct DeterministicStubBackend {
    models: ModelPinConfig,
}

impl DeterministicStubBackend {
    pub fn new(models: ModelPinConfig) -> Self {
        Self { models }
    }

    pub fn models(&self) -> &ModelPinConfig {
        &self.models
    }
}

impl InferenceBackend for DeterministicStubBackend {
    fn detect_objects(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<RawDetection>, MediaWorkerError> {
        Ok(detect_stub_objects(frame, min_confidence))
    }

    fn encode_images(&self, frames: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
        let dim = self.models.embedding_dim();
        let mut out = Vec::with_capacity(frames.len());
        for frame in frames {
            let colors = classify_dominant_colors(frame, None);
            out.push(encode_stub_visual_region(
                frame,
                None,
                &colors,
                &self.models,
                dim,
            ));
        }
        Ok(out)
    }

    fn encode_text(&self, query: &str) -> Result<Vec<f32>, MediaWorkerError> {
        embed_query_text(query, &self.models)
    }

    fn info(&self) -> InferenceBackendInfo {
        InferenceBackendInfo::new(
            InferenceBackendKind::Stub,
            "cpu",
            self.models.embedding_dim(),
            format!(
                "{}:{}",
                self.models.embedder_model_id(),
                self.models.embedder_model_version()
            ),
            true,
        )
    }

    fn encode_annotated_images(
        &self,
        regions: &[(&RgbFrame, Option<ObjectClass>, &[String])],
    ) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
        let dim = self.models.embedding_dim();
        let mut out = Vec::with_capacity(regions.len());
        for (frame, class, colors) in regions {
            let fallback_colors;
            let effective_colors = if class.is_none() && colors.is_empty() {
                fallback_colors = classify_dominant_colors(frame, None);
                fallback_colors.as_slice()
            } else {
                *colors
            };
            out.push(encode_stub_visual_region(
                frame,
                *class,
                effective_colors,
                &self.models,
                dim,
            ));
        }
        Ok(out)
    }
}

/// Instantiates the configured `InferenceBackend` (`stub` or local-filesystem `candle`).
pub fn build_inference_backend(
    config: &WorkerConfig,
) -> Result<Arc<dyn InferenceBackend>, MediaWorkerError> {
    config
        .device_preference()
        .validate_provider(config.execution_provider().requires_gpu())?;
    config
        .backend_kind()
        .validate_provider(config.execution_provider())?;
    match config.backend_kind() {
        InferenceBackendKind::Stub => Ok(Arc::new(DeterministicStubBackend::new(
            config.models().clone(),
        ))),
        InferenceBackendKind::Candle => {
            let model_dir = config.model_dir().ok_or_else(|| {
                MediaWorkerError::capability(CapabilityError::invalid_configuration(
                    "MEDIA_WORKER_BACKEND=candle requires MEDIA_WORKER_MODEL_DIR to be set",
                ))
            })?;
            // The model identity deliberately excludes the compute precision: f16 and
            // f32 embeddings stay interchangeable for search (README "Precision").
            let revision = format!(
                "{}:{}",
                config.models().embedder_model_id(),
                config.models().embedder_model_version()
            );
            let mut options = CandleBackendOptions::new(
                config.device_preference(),
                config.execution_provider().requires_gpu(),
                config.models().embedding_dim(),
            )
            .with_precision(config.precision())
            .with_model_revision(revision)
            .with_preprocess_threads(preprocess_thread_budget(config.index_concurrency()));
            if let Some(detector) = config.models().detector_path() {
                options = options.with_detector_path(detector);
            }
            let backend = CandleBackend::load(model_dir, &options)?;
            Ok(Arc::new(backend))
        }
    }
}
