use serde::{Deserialize, Serialize};
use super::flowgger_input::FlowggerInput;
use super::otel_input::OtelInput;
use super::health_config::HealthConfig;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub flowgger: FlowggerInput,

    #[serde(default)]
    pub otel: OtelInput,

    #[serde(default)]
    pub health: HealthConfig,
}
