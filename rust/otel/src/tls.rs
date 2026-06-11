use log::{debug, info, warn};
use std::fs;
use tonic::transport::{Identity, ServerTlsConfig};

use crate::config::{ClientAuthMode, Config};

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

    // Client certificate policy. "none" lets operators expose external OTLP
    // ingest with server-side TLS only, even when a CA file is configured
    // for other purposes; "optional" verifies certificates when presented
    // but does not require them; "required" (default) is strict mTLS.
    match (tls.client_auth, tls.ca_file.as_ref()) {
        (ClientAuthMode::None, ca_file) => {
            if ca_file.is_some() {
                info!(
                    "gRPC TLS client authentication disabled (client_auth = \"none\"); ignoring configured ca_file"
                );
            } else {
                debug!("gRPC TLS client authentication disabled (client_auth = \"none\")");
            }
        }
        (mode, Some(ca_file)) => {
            debug!("Loading gRPC TLS CA certificate from: {ca_file}");
            let ca_cert = fs::read(ca_file).map_err(|e| {
                format!("Failed to read gRPC TLS CA certificate file '{ca_file}': {e}")
            })?;

            let ca_cert = tonic::transport::Certificate::from_pem(ca_cert);
            tls_config = tls_config.client_ca_root(ca_cert);
            if mode == ClientAuthMode::Optional {
                tls_config = tls_config.client_auth_optional(true);
                info!("gRPC TLS client authentication optional with CA: {ca_file}");
            } else {
                info!("gRPC TLS client authentication required with CA: {ca_file}");
            }
        }
        (mode, None) => {
            // No CA configured: there is nothing to verify client
            // certificates against, so client auth stays off regardless of
            // the requested mode.
            if mode == ClientAuthMode::Required {
                warn!(
                    "gRPC TLS client_auth = \"required\" but no ca_file configured; client certificates will not be requested"
                );
            }
        }
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
            ..Default::default()
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
            ..Default::default()
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
                client_auth: crate::config::ClientAuthMode::Required,
            }),
            ..Default::default()
        };

        // This should not panic
        log_tls_info(&config);
    }

    #[test]
    fn test_setup_grpc_tls_client_auth_none_skips_ca() {
        use std::io::Write;

        // Self-signed test material is not needed: client_auth = "none" must
        // not even attempt to read the CA file, and the identity is loaded
        // verbatim (validation happens at handshake time).
        let mut cert = tempfile::NamedTempFile::new().unwrap();
        cert.write_all(b"-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n")
            .unwrap();
        let mut key = tempfile::NamedTempFile::new().unwrap();
        key.write_all(b"-----BEGIN PRIVATE KEY-----\nZmFrZQ==\n-----END PRIVATE KEY-----\n")
            .unwrap();

        let config = Config {
            server: ServerConfig::default(),
            nats: None,
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: cert.path().to_str().unwrap().to_string(),
                key_file: key.path().to_str().unwrap().to_string(),
                // Deliberately points at a missing file: must NOT be read.
                ca_file: Some("/nonexistent/ca.pem".to_string()),
                client_auth: crate::config::ClientAuthMode::None,
            }),
            ..Default::default()
        };

        let result = setup_grpc_tls(&config).unwrap();
        assert!(result.is_some());
    }

    #[test]
    fn test_setup_grpc_tls_client_auth_required_missing_ca_file_errors() {
        use std::io::Write;

        let mut cert = tempfile::NamedTempFile::new().unwrap();
        cert.write_all(b"-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n")
            .unwrap();
        let mut key = tempfile::NamedTempFile::new().unwrap();
        key.write_all(b"-----BEGIN PRIVATE KEY-----\nZmFrZQ==\n-----END PRIVATE KEY-----\n")
            .unwrap();

        let config = Config {
            server: ServerConfig::default(),
            nats: None,
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: cert.path().to_str().unwrap().to_string(),
                key_file: key.path().to_str().unwrap().to_string(),
                ca_file: Some("/nonexistent/ca.pem".to_string()),
                client_auth: crate::config::ClientAuthMode::Required,
            }),
            ..Default::default()
        };

        // Required client auth with an unreadable CA must fail loudly.
        assert!(setup_grpc_tls(&config).is_err());
    }
}
