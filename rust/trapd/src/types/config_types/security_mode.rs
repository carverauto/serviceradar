use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    #[default]
    #[serde(alias = "", alias = "mtls")]
    Mtls,
    Spiffe,
    None,
}
