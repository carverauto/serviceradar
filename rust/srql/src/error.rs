use thiserror::Error;

pub type Result<T> = std::result::Result<T, ServiceError>;

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("configuration error: {0}")]
    Config(String),

    #[error("authentication failed")]
    Auth,

    #[error("invalid request: {0}")]
    InvalidRequest(String),

    /// The caller is not permitted to read what the query asks for. Distinct
    /// from `InvalidRequest` so an embedding caller can map it to its own
    /// forbidden outcome (HTTP 403) by the `forbidden: ` message prefix.
    #[error("forbidden: {0}")]
    Forbidden(String),

    #[error("not implemented: {0}")]
    NotImplemented(String),

    #[error("internal error")]
    Internal(#[from] anyhow::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forbidden_keeps_prefixed_message() {
        let err = ServiceError::Forbidden("signal 'traces' is not permitted".into());
        assert_eq!(
            err.to_string(),
            "forbidden: signal 'traces' is not permitted"
        );
    }
}
