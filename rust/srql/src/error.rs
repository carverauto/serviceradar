use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;
use thiserror::Error;
use tracing::error;

pub type Result<T> = std::result::Result<T, ServiceError>;

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("configuration error: {0}")]
    Config(String),

    #[error("authentication failed")]
    Auth,

    #[error("invalid request: {0}")]
    InvalidRequest(String),

    #[error("not implemented: {0}")]
    NotImplemented(String),

    #[error("internal error")]
    Internal(#[from] anyhow::Error),
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

impl IntoResponse for ServiceError {
    fn into_response(self) -> Response {
        let status = match self {
            ServiceError::Config(_) => StatusCode::INTERNAL_SERVER_ERROR,
            ServiceError::Auth => StatusCode::UNAUTHORIZED,
            ServiceError::InvalidRequest(_) => StatusCode::BAD_REQUEST,
            ServiceError::NotImplemented(_) => StatusCode::NOT_IMPLEMENTED,
            ServiceError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };

        if !matches!(self, ServiceError::InvalidRequest(_) | ServiceError::Auth) {
            error!(error = %self, "request failed");
        }

        let body = ErrorBody {
            error: self.to_string(),
        };
        (status, Json(body)).into_response()
    }
}
