use serde::{Deserialize, Serialize};

/// ZFS configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZfsConfig {
    pub enabled: bool,
    pub pools: Vec<String>,
    pub include_datasets: bool,
    pub use_libzetta: bool,
}

impl std::fmt::Display for ZfsConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}