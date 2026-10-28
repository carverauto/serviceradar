use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    thread,
};

use anyhow::{Context, Result, anyhow};
use log::{error, info};
use tonic::transport::{Certificate, Identity, Server, ServerTlsConfig};
use tonic_health::{ServingStatus, server::health_reporter};

use super::config::Config;

pub fn maybe_spawn(config: &Config) {
    let settings = match GrpcSettings::from_config(config) {
        Ok(Some(settings)) => settings,
        Ok(None) => return,
        Err(err) => {
            error!("flowgger gRPC disabled: invalid configuration: {err:#}");
            return;
        }
    };

    info!(
        "flowgger gRPC configuration detected for {}, preparing server",
        settings.listen_addr
    );

    if let Err(err) = spawn_server(settings) {
        error!("flowgger gRPC disabled: failed to spawn server: {err:#}");
    }
}

fn spawn_server(settings: GrpcSettings) -> Result<()> {
    thread::Builder::new()
        .name("flowgger-grpc".into())
        .spawn(move || {
            info!("flowgger gRPC server starting on {}", settings.listen_addr);
            if let Err(err) = run_server(settings) {
                error!("flowgger gRPC server exited: {err:#}");
            }
        })?;

    Ok(())
}

fn run_server(settings: GrpcSettings) -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_io()
        .enable_time()
        .build()?;

    rt.block_on(async move {
        let addr: SocketAddr = settings.listen_addr.parse().with_context(|| {
            format!("failed to parse grpc.listen_addr {}", settings.listen_addr)
        })?;

        match settings.security {
            SecuritySettings::Mtls(tls) => {
                let tls = tls
                    .tls_config()
                    .context("failed to configure mTLS for flowgger gRPC server")?;
                serve_with_tls(addr, tls).await
            }
        }
    })
}

#[derive(Debug, PartialEq, Eq)]
struct GrpcSettings {
    listen_addr: String,
    security: SecuritySettings,
}

#[derive(Debug, PartialEq, Eq)]
struct TlsSettings {
    cert_path: PathBuf,
    key_path: PathBuf,
    client_ca_path: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
enum SecuritySettings {
    Mtls(TlsSettings),
}

impl GrpcSettings {
    fn from_config(config: &Config) -> Result<Option<Self>> {
        let listen = match read_string(config, "grpc.listen_addr") {
            Some(value) if !value.is_empty() => value,
            _ => return Ok(None),
        };

        let cert_dir = read_string(config, "grpc.cert_dir");
        let mode = read_string(config, "grpc.mode")
            .map(|m| m.to_ascii_lowercase())
            .unwrap_or_else(|| "mtls".to_string());

        let security = match mode.as_str() {
            "none" => {
                return Err(anyhow!(
                    "grpc.mode \"none\" is not allowed for the flowgger gRPC sidecar"
                ));
            }
            "mtls" => {
                SecuritySettings::Mtls(TlsSettings::from_config(cert_dir.as_deref(), config)?)
            }
            other => {
                return Err(anyhow!(
                    "unsupported grpc.mode '{other}' (see https://docs.serviceradar.cloud/docs/migrating-off-spire)"
                ));
            }
        };

        Ok(Some(GrpcSettings {
            listen_addr: listen,
            security,
        }))
    }
}

impl TlsSettings {
    fn from_config(cert_dir: Option<&str>, config: &Config) -> Result<Self> {
        let cert = read_string(config, "grpc.cert_file");
        let key = read_string(config, "grpc.key_file");
        let client_ca = read_string(config, "grpc.client_ca_file")
            .or_else(|| read_string(config, "grpc.ca_file"));

        if cert.is_none() && key.is_none() && client_ca.is_none() {
            return Err(anyhow!(
                "grpc.cert_file, grpc.key_file, and grpc.client_ca_file or grpc.ca_file are required in mTLS mode"
            ));
        }

        let cert = cert.ok_or_else(|| anyhow!("grpc.cert_file is required in mTLS mode"))?;
        let key = key.ok_or_else(|| anyhow!("grpc.key_file is required in mTLS mode"))?;
        let client_ca = client_ca.ok_or_else(|| {
            anyhow!("grpc.client_ca_file or grpc.ca_file is required in mTLS mode")
        })?;

        Ok(TlsSettings {
            cert_path: resolve_path(cert_dir, cert),
            key_path: resolve_path(cert_dir, key),
            client_ca_path: resolve_path(cert_dir, client_ca),
        })
    }

    fn tls_config(&self) -> Result<ServerTlsConfig> {
        let cert_bytes = fs::read(&self.cert_path).with_context(|| {
            format!(
                "failed to read TLS certificate from {}",
                self.cert_path.display()
            )
        })?;
        let key_bytes = fs::read(&self.key_path)
            .with_context(|| format!("failed to read TLS key from {}", self.key_path.display()))?;
        let ca_bytes = fs::read(&self.client_ca_path).with_context(|| {
            format!(
                "failed to read client CA certificate from {}",
                self.client_ca_path.display()
            )
        })?;

        let identity = Identity::from_pem(cert_bytes, key_bytes);
        let client_ca = Certificate::from_pem(ca_bytes);

        Ok(ServerTlsConfig::new()
            .identity(identity)
            .client_ca_root(client_ca))
    }
}

async fn serve_with_tls(addr: SocketAddr, tls: ServerTlsConfig) -> Result<()> {
    let (reporter, health_service) = health_reporter();

    reporter
        .set_service_status("", ServingStatus::Serving)
        .await;
    reporter
        .set_service_status("flowgger", ServingStatus::Serving)
        .await;

    Server::builder()
        .tls_config(tls)?
        .add_service(health_service)
        .serve(addr)
        .await
        .context("flowgger gRPC server failed")
}

fn read_string(config: &Config, key: &str) -> Option<String> {
    config
        .lookup(key)
        .and_then(|v| v.as_str().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
}

fn resolve_path(cert_dir: Option<&str>, value: String) -> PathBuf {
    let trimmed = value.trim();
    let path = Path::new(trimmed);
    match (path.is_absolute(), cert_dir) {
        (true, _) => path.to_path_buf(),
        (_, None) => path.to_path_buf(),
        (_, Some(dir)) => Path::new(dir).join(path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_config(toml: &str) -> Config {
        Config::from_string(toml).expect("failed to parse config snippet")
    }

    #[test]
    fn spiffe_mode_is_rejected() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "spiffe"
            trust_domain = "example.test"
        "#,
        );

        let err = GrpcSettings::from_config(&config).expect_err("expected failure");
        assert!(
            err.to_string().contains("unsupported grpc.mode 'spiffe'"),
            "error should reject spiffe mode: {err}"
        );
    }

    #[test]
    fn none_mode_is_rejected() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "none"
        "#,
        );

        let err = GrpcSettings::from_config(&config).expect_err("expected failure");
        assert!(
            err.to_string().contains("grpc.mode \"none\""),
            "error should mention rejected none mode: {err}"
        );
    }

    #[test]
    fn mtls_without_paths_is_rejected() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "mtls"
        "#,
        );

        let err = GrpcSettings::from_config(&config).expect_err("expected failure");
        assert!(
            err.to_string().contains("grpc.cert_file")
                || err.to_string().contains("required in mTLS mode"),
            "error should mention missing mTLS paths: {err}"
        );
    }

    #[test]
    fn mtls_with_paths_resolves_tls_settings() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "mtls"
            cert_dir = "/etc/serviceradar/certs"
            cert_file = "flowgger.pem"
            key_file = "flowgger-key.pem"
            ca_file = "root.pem"
        "#,
        );

        let settings = GrpcSettings::from_config(&config)
            .expect("config parsing failed")
            .expect("expected settings");
        let SecuritySettings::Mtls(tls) = settings.security;
        assert_eq!(
            tls.cert_path,
            PathBuf::from("/etc/serviceradar/certs/flowgger.pem")
        );
        assert_eq!(
            tls.key_path,
            PathBuf::from("/etc/serviceradar/certs/flowgger-key.pem")
        );
        assert_eq!(
            tls.client_ca_path,
            PathBuf::from("/etc/serviceradar/certs/root.pem")
        );
    }
}
