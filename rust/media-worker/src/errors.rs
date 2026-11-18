//! Concrete typed errors for `serviceradar-media-worker`.

use core::fmt::{self, Display, Formatter};

/// Classification of startup capability admission failures.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum CapabilityErrorKind {
    /// Configured GPU execution provider (`cuda` or `tensorrt`) is unavailable;
    /// worker refuses startup with zero silent CPU fallback.
    GpuUnavailable(String),
    /// ONNX Runtime shared library or C-ABI entry point failed to load.
    OrtRuntimeUnavailable(String),
    /// Pinned ONNX model artifact on disk does not match configured SHA-256 digest.
    ModelDigestMismatch {
        role: String,
        expected: String,
        actual: String,
    },
    /// Configured model artifact file is missing or unreadable.
    ModelArtifactMissing { role: String, path: String },
    /// Worker configuration violates safety or resource bounds.
    InvalidConfiguration(String),
}

/// Startup capability admission error (`2.2`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CapabilityError(CapabilityErrorKind);

impl CapabilityError {
    pub(crate) fn new(kind: CapabilityErrorKind) -> Self {
        Self(kind)
    }

    /// Inspect the concrete failure classification.
    pub fn kind(&self) -> &CapabilityErrorKind {
        &self.0
    }

    pub fn gpu_unavailable(reason: impl Into<String>) -> Self {
        Self::new(CapabilityErrorKind::GpuUnavailable(reason.into()))
    }

    pub fn ort_runtime_unavailable(reason: impl Into<String>) -> Self {
        Self::new(CapabilityErrorKind::OrtRuntimeUnavailable(reason.into()))
    }

    pub fn model_digest_mismatch(
        role: impl Into<String>,
        expected: impl Into<String>,
        actual: impl Into<String>,
    ) -> Self {
        Self::new(CapabilityErrorKind::ModelDigestMismatch {
            role: role.into(),
            expected: expected.into(),
            actual: actual.into(),
        })
    }

    pub fn model_artifact_missing(role: impl Into<String>, path: impl Into<String>) -> Self {
        Self::new(CapabilityErrorKind::ModelArtifactMissing {
            role: role.into(),
            path: path.into(),
        })
    }

    pub fn invalid_configuration(reason: impl Into<String>) -> Self {
        Self::new(CapabilityErrorKind::InvalidConfiguration(reason.into()))
    }
}

impl Display for CapabilityError {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match &self.0 {
            CapabilityErrorKind::GpuUnavailable(msg) => {
                write!(f, "GPU execution provider unavailable (fail-closed): {msg}")
            }
            CapabilityErrorKind::OrtRuntimeUnavailable(msg) => {
                write!(f, "ONNX Runtime unavailable: {msg}")
            }
            CapabilityErrorKind::ModelDigestMismatch {
                role,
                expected,
                actual,
            } => {
                write!(
                    f,
                    "model SHA-256 mismatch for {role}: expected {expected}, got {actual}"
                )
            }
            CapabilityErrorKind::ModelArtifactMissing { role, path } => {
                write!(f, "model artifact missing for {role} at {path}")
            }
            CapabilityErrorKind::InvalidConfiguration(msg) => {
                write!(f, "invalid media worker configuration: {msg}")
            }
        }
    }
}

impl std::error::Error for CapabilityError {}

/// Classification of media byte integrity and capability scope failures.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum IntegrityErrorKind {
    /// Fetched `init.mp4` or fragment bytes failed SHA-256 verification against frozen descriptor.
    DigestMismatch {
        target: String,
        expected: String,
        actual: String,
    },
    /// Expected SHA-256 string is not 64 lowercase hexadecimal characters.
    InvalidHexDigest(String),
    /// Slice offset/length exceeds fetched coalesced range buffer.
    OutOfBoundsSlice {
        sequence: u32,
        relative_offset: u64,
        length: u64,
        chunk_len: usize,
    },
    /// Requested or returned byte range exceeds the 4 MiB coalescing bound.
    RangeTooLarge { length: u64, max_bytes: u64 },
    /// Execution-time grant violated reader-only or endpoint scope invariants.
    GrantScopeViolation(String),
}

/// Media integrity or capability-scope verification error (`2.3`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct IntegrityError(IntegrityErrorKind);

impl IntegrityError {
    pub(crate) fn new(kind: IntegrityErrorKind) -> Self {
        Self(kind)
    }

    /// Inspect the concrete integrity failure classification.
    pub fn kind(&self) -> &IntegrityErrorKind {
        &self.0
    }

    pub fn digest_mismatch(
        target: impl Into<String>,
        expected: impl Into<String>,
        actual: impl Into<String>,
    ) -> Self {
        Self::new(IntegrityErrorKind::DigestMismatch {
            target: target.into(),
            expected: expected.into(),
            actual: actual.into(),
        })
    }

    pub fn invalid_hex_digest(value: impl Into<String>) -> Self {
        Self::new(IntegrityErrorKind::InvalidHexDigest(value.into()))
    }

    pub fn out_of_bounds_slice(
        sequence: u32,
        relative_offset: u64,
        length: u64,
        chunk_len: usize,
    ) -> Self {
        Self::new(IntegrityErrorKind::OutOfBoundsSlice {
            sequence,
            relative_offset,
            length,
            chunk_len,
        })
    }

    pub fn range_too_large(length: u64, max_bytes: u64) -> Self {
        Self::new(IntegrityErrorKind::RangeTooLarge { length, max_bytes })
    }

    pub fn grant_scope_violation(reason: impl Into<String>) -> Self {
        Self::new(IntegrityErrorKind::GrantScopeViolation(reason.into()))
    }
}

impl Display for IntegrityError {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match &self.0 {
            IntegrityErrorKind::DigestMismatch {
                target,
                expected,
                actual,
            } => write!(
                f,
                "SHA-256 digest mismatch for {target}: expected {expected}, got {actual}"
            ),
            IntegrityErrorKind::InvalidHexDigest(val) => {
                write!(
                    f,
                    "invalid 64-character lowercase hex SHA-256 digest: {val}"
                )
            }
            IntegrityErrorKind::OutOfBoundsSlice {
                sequence,
                relative_offset,
                length,
                chunk_len,
            } => write!(
                f,
                "fragment {sequence} slice ({relative_offset}+{length}) exceeds chunk length {chunk_len}"
            ),
            IntegrityErrorKind::RangeTooLarge { length, max_bytes } => {
                write!(
                    f,
                    "byte range length {length} exceeds maximum allowed {max_bytes}"
                )
            }
            IntegrityErrorKind::GrantScopeViolation(msg) => {
                write!(f, "read grant scope violation: {msg}")
            }
        }
    }
}

impl std::error::Error for IntegrityError {}

/// Top-level error classification for `serviceradar-media-worker`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum MediaWorkerErrorKind {
    Capability(CapabilityError),
    Integrity(IntegrityError),
    ControlPlaneRejected { status: u16, reason: String },
    StorageTransport(String),
    InvalidContainer(String),
    InferenceFailed(String),
    NatsError(String),
    InvalidJobEnvelope(String),
    InvalidTextEmbedRequest(String),
    DeadlineExceeded(String),
}

/// Top-level media worker operational error.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MediaWorkerError(MediaWorkerErrorKind);

impl MediaWorkerError {
    pub(crate) fn new(kind: MediaWorkerErrorKind) -> Self {
        Self(kind)
    }

    pub fn kind(&self) -> &MediaWorkerErrorKind {
        &self.0
    }

    pub fn capability(err: CapabilityError) -> Self {
        Self::new(MediaWorkerErrorKind::Capability(err))
    }

    pub fn integrity(err: IntegrityError) -> Self {
        Self::new(MediaWorkerErrorKind::Integrity(err))
    }

    pub fn control_plane_rejected(status: u16, reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::ControlPlaneRejected {
            status,
            reason: reason.into(),
        })
    }

    pub fn storage_transport(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::StorageTransport(reason.into()))
    }

    pub fn invalid_container(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::InvalidContainer(reason.into()))
    }

    pub fn inference_failed(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::InferenceFailed(reason.into()))
    }

    pub fn nats_error(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::NatsError(reason.into()))
    }

    pub fn invalid_job_envelope(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::InvalidJobEnvelope(reason.into()))
    }

    pub fn invalid_text_embed_request(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::InvalidTextEmbedRequest(reason.into()))
    }

    pub fn deadline_exceeded(reason: impl Into<String>) -> Self {
        Self::new(MediaWorkerErrorKind::DeadlineExceeded(reason.into()))
    }

    /// Bounded error class identifier suitable for telemetry counters.
    pub fn error_class(&self) -> &'static str {
        match &self.0 {
            MediaWorkerErrorKind::Capability(_) => "capability_error",
            MediaWorkerErrorKind::Integrity(err) => match err.kind() {
                IntegrityErrorKind::DigestMismatch { .. } => "integrity_mismatch",
                IntegrityErrorKind::GrantScopeViolation(_) => "grant_scope_violation",
                _ => "integrity_error",
            },
            MediaWorkerErrorKind::ControlPlaneRejected { .. } => "control_plane_rejected",
            MediaWorkerErrorKind::StorageTransport(_) => "storage_transport",
            MediaWorkerErrorKind::InvalidContainer(_) => "invalid_container",
            MediaWorkerErrorKind::InferenceFailed(_) => "inference_failed",
            MediaWorkerErrorKind::NatsError(_) => "nats_error",
            MediaWorkerErrorKind::InvalidJobEnvelope(_) => "invalid_job_envelope",
            MediaWorkerErrorKind::InvalidTextEmbedRequest(_) => "invalid_text_embed_request",
            MediaWorkerErrorKind::DeadlineExceeded(_) => "deadline_exceeded",
        }
    }
}

impl From<CapabilityError> for MediaWorkerError {
    fn from(value: CapabilityError) -> Self {
        Self::capability(value)
    }
}

impl From<IntegrityError> for MediaWorkerError {
    fn from(value: IntegrityError) -> Self {
        Self::integrity(value)
    }
}

impl Display for MediaWorkerError {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match &self.0 {
            MediaWorkerErrorKind::Capability(err) => Display::fmt(err, f),
            MediaWorkerErrorKind::Integrity(err) => Display::fmt(err, f),
            MediaWorkerErrorKind::ControlPlaneRejected { status, reason } => {
                write!(f, "control plane grant rejected (HTTP {status}): {reason}")
            }
            MediaWorkerErrorKind::StorageTransport(msg) => {
                write!(f, "storage transport error: {msg}")
            }
            MediaWorkerErrorKind::InvalidContainer(msg) => {
                write!(f, "invalid ISO-BMFF/CMAF container: {msg}")
            }
            MediaWorkerErrorKind::InferenceFailed(msg) => {
                write!(f, "vision/text inference failed: {msg}")
            }
            MediaWorkerErrorKind::NatsError(msg) => write!(f, "NATS error: {msg}"),
            MediaWorkerErrorKind::InvalidJobEnvelope(msg) => {
                write!(f, "invalid visual index job envelope: {msg}")
            }
            MediaWorkerErrorKind::InvalidTextEmbedRequest(msg) => {
                write!(f, "invalid text embed RPC request: {msg}")
            }
            MediaWorkerErrorKind::DeadlineExceeded(msg) => {
                write!(f, "deadline exceeded: {msg}")
            }
        }
    }
}

impl std::error::Error for MediaWorkerError {}
