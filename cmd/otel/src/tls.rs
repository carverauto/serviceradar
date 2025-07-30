use log::{debug, info};
use std::fs;
use tonic::transport::{Identity, ServerTlsConfig};

use crate::config::Config;

/// Sets up gRPC TLS configuration from the provided config
pub fn setup_grpc_tls(
    config: &Config,
) -> Result<Option<ServerTlsConfig>, Box<dyn std::error::Error>> {
    let Some(ref tls) = config.grpc_tls else {
        return Ok(None);
    };

    debug!("Loading gRPC TLS certificate from: {}", tls.cert_file);
    let cert = fs::read(&tls.cert_file).map_err(|e| {
        format!(
            "Failed to read gRPC TLS certificate file '{}': {e}",
            tls.cert_file
        )
    })?;

    debug!("Loading gRPC TLS private key from: {}", tls.key_file);
    let key = fs::read(&tls.key_file).map_err(|e| {
        format!(
            "Failed to read gRPC TLS private key file '{}': {e}",
            tls.key_file
        )
    })?;

    let identity = Identity::from_pem(cert, key);
    let mut tls_config = ServerTlsConfig::new().identity(identity);

    // Add client CA if provided
    if let Some(ref ca_file) = tls.ca_file {
        debug!("Loading gRPC TLS CA certificate from: {ca_file}");
        let ca_cert = fs::read(ca_file)
            .map_err(|e| format!("Failed to read gRPC TLS CA certificate file '{ca_file}': {e}"))?;

        let ca_cert = tonic::transport::Certificate::from_pem(ca_cert);
        tls_config = tls_config.client_ca_root(ca_cert);
        info!("gRPC TLS client authentication enabled with CA: {ca_file}");
    }

    Ok(Some(tls_config))
}

/// Logs TLS configuration information
pub fn log_tls_info(config: &Config) {
    if let Some(ref tls) = config.grpc_tls {
        info!(
            "gRPC TLS enabled - cert: {}, key: {}",
            tls.cert_file, tls.key_file
        );
        if let Some(ref ca) = tls.ca_file {
            debug!("gRPC TLS CA file: {ca}");
        }
    } else {
        info!("gRPC TLS disabled (no [grpc_tls] section in config)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, GRPCTLSConfig, ServerConfig};

    #[test]
    fn test_setup_grpc_tls_disabled() {
        let config = Config {
            server: ServerConfig::default(),
            nats: None,
            grpc_tls: None,
        };

        let result = setup_grpc_tls(&config).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_log_tls_info_disabled() {
        let config = Config {
            server: ServerConfig::default(),
            nats: None,
            grpc_tls: None,
        };

        // This should not panic
        log_tls_info(&config);
    }

    #[test]
    fn test_log_tls_info_enabled() {
        let config = Config {
            server: ServerConfig::default(),
            nats: None,
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: "/test.crt".to_string(),
                key_file: "/test.key".to_string(),
                ca_file: Some("/test-ca.pem".to_string()),
            }),
        };

        // This should not panic
        log_tls_info(&config);
    }
}
