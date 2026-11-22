//! Typed errors for `serviceradar-media-core`.

use thiserror::Error;

/// Error category for `serviceradar-media-core` operations.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum MediaCoreErrorKind {
    #[error("invalid configuration: {0}")]
    InvalidConfiguration(String),
    #[error("invalid frame: {0}")]
    InvalidFrame(String),
    #[error("detector error: {0}")]
    Detector(String),
    #[error("thumbnail encoding error: {0}")]
    Thumbnail(String),
}

/// Top-level typed error returned by `serviceradar-media-core` APIs.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("{0}")]
pub struct MediaCoreError(#[from] pub MediaCoreErrorKind);

impl MediaCoreError {
    pub fn invalid_configuration(detail: impl Into<String>) -> Self {
        Self(MediaCoreErrorKind::InvalidConfiguration(detail.into()))
    }

    pub fn invalid_frame(detail: impl Into<String>) -> Self {
        Self(MediaCoreErrorKind::InvalidFrame(detail.into()))
    }

    pub fn detector(detail: impl Into<String>) -> Self {
        Self(MediaCoreErrorKind::Detector(detail.into()))
    }

    pub fn thumbnail(detail: impl Into<String>) -> Self {
        Self(MediaCoreErrorKind::Thumbnail(detail.into()))
    }

    pub fn kind(&self) -> &MediaCoreErrorKind {
        &self.0
    }
}
