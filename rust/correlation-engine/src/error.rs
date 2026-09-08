//! Error type for the correlation engine.

use thiserror::Error;

/// Errors raised across the engine's hydrate → reason → emit pipeline.
#[derive(Debug, Error)]
pub enum CorrelationEngineError {
    /// Configuration could not be loaded/validated.
    #[error("config error: {0}")]
    Config(String),

    /// Context hydration (EmbeddedSrql / JetStream / state-change feed) failed.
    #[error("hydration error: {0}")]
    Hydration(String),

    /// NATS connection or subscription error.
    #[error("nats error: {0}")]
    Nats(String),

    /// Rule / dependency-graph reasoning failed.
    #[error("reasoning error: {0}")]
    Reasoning(String),

    /// Verdict emission (signals.analytics.predictions) failed.
    #[error("emit error: {0}")]
    Emit(String),

    /// Snapshot persistence/restore failed.
    #[error("snapshot error: {0}")]
    Snapshot(String),
}

/// Convenience result alias for the crate.
pub type Result<T> = std::result::Result<T, CorrelationEngineError>;
