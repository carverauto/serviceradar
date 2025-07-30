use log::{debug, error, info, warn};
use std::net::SocketAddr;

use crate::cli::CLI;
use crate::config::Config;

/// Sets up logging and parses command line arguments
pub fn setup_logging_and_parse_args() -> Result<CLI, Box<dyn std::error::Error>> {
    let args = CLI::parse_args();

    let log_level = if args.is_debug_enabled() {
        "debug"
    } else {
        "info"
    };

    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or(log_level)).init();

    debug!("Debug logging enabled");
    info!("ServiceRadar OTEL Collector starting up");

    Ok(args)
}

/// Handles the generate-config command
pub fn handle_generate_config() -> Result<(), Box<dyn std::error::Error>> {
    info!("Generating example configuration");
    println!("{}", Config::example_toml());
    Ok(())
}

/// Loads configuration from the specified path or defaults
pub fn load_configuration(args: &CLI) -> Result<Config, Box<dyn std::error::Error>> {
    debug!("Loading configuration from: {:?}", args.config);

    match Config::load(args.config.as_deref()) {
        Ok(cfg) => {
            debug!("Configuration loaded successfully");
            Ok(cfg)
        }
        Err(e) => {
            error!("Failed to load configuration: {e}");
            if args.config.is_some() {
                // If a specific config was requested and failed, exit
                Err(e.into())
            } else {
                warn!("Using default configuration");
                Ok(Config::default())
            }
        }
    }
}

/// Parses the bind address from configuration
pub fn parse_bind_address(config: &Config) -> Result<SocketAddr, Box<dyn std::error::Error>> {
    debug!("Parsing bind address: {}", config.bind_address());

    config
        .bind_address()
        .parse()
        .map_err(|e| format!("Invalid bind address '{}': {}", config.bind_address(), e).into())
}

/// Logs configuration information
pub fn log_configuration_info(config: &Config) {
    // Log NATS configuration
    if let Some(nats) = config.nats_config() {
        info!(
            "NATS output enabled - URL: {}, Subject: {}, Stream: {}",
            nats.url, nats.subject, nats.stream
        );
        debug!("NATS timeout: {:?}", nats.timeout);
        debug!("NATS TLS cert: {:?}", nats.tls_cert);
        debug!("NATS TLS key: {:?}", nats.tls_key);
        debug!("NATS TLS CA: {:?}", nats.tls_ca);
    } else {
        info!("NATS output disabled (no [nats] section in config)");
    }

    // Log gRPC TLS configuration (delegated to tls module)
    crate::tls::log_tls_info(config);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, ServerConfig};

    #[test]
    fn test_parse_bind_address_valid() {
        let config = Config {
            server: ServerConfig {
                bind_address: "127.0.0.1".to_string(),
                port: 8080,
            },
            nats: None,
            grpc_tls: None,
        };

        let addr = parse_bind_address(&config).unwrap();
        assert_eq!(addr.port(), 8080);
        assert_eq!(addr.ip().to_string(), "127.0.0.1");
    }

    #[test]
    fn test_parse_bind_address_invalid() {
        let config = Config {
            server: ServerConfig {
                bind_address: "invalid".to_string(),
                port: 8080,
            },
            nats: None,
            grpc_tls: None,
        };

        let result = parse_bind_address(&config);
        assert!(result.is_err());
    }

    #[test]
    fn test_log_configuration_info() {
        let config = Config::default();
        // This should not panic
        log_configuration_info(&config);
    }

    #[test]
    fn test_handle_generate_config() {
        let result = handle_generate_config();
        assert!(result.is_ok());
    }
}
