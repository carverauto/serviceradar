use serde::{Deserialize, Serialize};

/// Security mode for the checker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    Mtls,
    Spiffe,
    #[default]
    None,
}