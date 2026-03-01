use thiserror::Error;

#[derive(Error, Debug)]
pub enum KvError {
    #[error("not found")]
    NotFound,
    #[error(transparent)]
    Other(#[from] Box<dyn std::error::Error + Send + Sync>),
}

pub type Result<T> = std::result::Result<T, KvError>;
