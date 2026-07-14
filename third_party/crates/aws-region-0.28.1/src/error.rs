use thiserror::Error;

#[derive(Error, Debug)]
pub enum RegionError {
    #[error("{source}")]
    Utf8 {
        #[from]
        source: std::str::Utf8Error,
    },
    #[error("{source}")]
    Env {
        #[from]
        source: std::env::VarError,
    },
}
