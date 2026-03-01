use serde::{Deserialize, Serialize};

/// Filesystem configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilesystemConfig {
    pub name: String,
    #[serde(rename = "type")]
    pub fs_type: String,
    pub monitor: bool,
}

impl std::fmt::Display for FilesystemConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}