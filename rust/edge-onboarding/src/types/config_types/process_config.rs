use serde::{Deserialize, Serialize};

pub(crate) fn default_include_all() -> bool {
    true
}


/// Process monitoring configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessConfig {
    pub enabled: bool,
    #[serde(default)]
    pub filter_by_name: Vec<String>,
    #[serde(default = "default_include_all")]
    pub include_all: bool,
}

impl std::fmt::Display for ProcessConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}