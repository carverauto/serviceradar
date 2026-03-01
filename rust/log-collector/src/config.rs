pub use crate::types::config_types::{Config, FlowggerInput, HealthConfig, OtelInput};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let config: Config = toml::from_str("").unwrap();
        assert!(config.flowgger.enabled);
        assert!(config.otel.enabled);
        assert_eq!(config.flowgger.config_file, "/etc/serviceradar/flowgger.toml");
        assert_eq!(config.otel.config_file, "/etc/serviceradar/otel.toml");
        assert_eq!(config.health.listen_addr, "0.0.0.0:50044");
    }

    #[test]
    fn test_disable_otel() {
        let config: Config = toml::from_str(
            r#"
            [otel]
            enabled = false
            "#,
        )
        .unwrap();
        assert!(config.flowgger.enabled);
        assert!(!config.otel.enabled);
    }

    #[test]
    fn test_custom_paths() {
        let config: Config = toml::from_str(
            r#"
            [flowgger]
            config_file = "/custom/flowgger.toml"

            [otel]
            config_file = "/custom/otel.toml"
            "#,
        )
        .unwrap();
        assert_eq!(config.flowgger.config_file, "/custom/flowgger.toml");
        assert_eq!(config.otel.config_file, "/custom/otel.toml");
    }
}
