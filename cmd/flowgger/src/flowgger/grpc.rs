use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    thread,
};

use anyhow::{anyhow, Context, Result};
use log::{error, info, warn};
use tonic::transport::{Certificate, Identity, Server, ServerTlsConfig};
use tonic_health::{server::health_reporter, ServingStatus};

use super::config::Config;
use super::spiffe;

const DEFAULT_WORKLOAD_SOCKET: &str = "unix:/run/spire/sockets/agent.sock";

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
            SecuritySettings::Spiffe(spiffe_cfg) => serve_with_spiffe(addr, spiffe_cfg)
                .await
                .context("flowgger gRPC server failed"),
            SecuritySettings::Mtls(tls) => {
                let tls = tls
                    .tls_config()
                    .context("failed to configure mTLS for flowgger gRPC server")?;
                serve_with_tls(addr, Some(tls)).await
            }
            SecuritySettings::None => {
                warn!("flowgger gRPC server starting without TLS; clients must allow plaintext");
                serve_with_tls(addr, None).await
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
struct SpiffeSettings {
    workload_socket: String,
    trust_domain: String,
}

#[derive(Debug, PartialEq, Eq)]
enum SecuritySettings {
    None,
    Mtls(TlsSettings),
    Spiffe(SpiffeSettings),
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
            "none" => SecuritySettings::None,
            "spiffe" => {
                let trust_domain = read_string(config, "grpc.trust_domain")
                    .ok_or_else(|| anyhow!("grpc.trust_domain is required for SPIFFE mode"))?;
                let workload_socket = read_string(config, "grpc.workload_socket")
                    .unwrap_or_else(|| DEFAULT_WORKLOAD_SOCKET.to_string());
                if workload_socket.trim().is_empty() {
                    return Err(anyhow!(
                        "grpc.workload_socket cannot be empty in SPIFFE mode"
                    ));
                }
                SecuritySettings::Spiffe(SpiffeSettings {
                    trust_domain,
                    workload_socket,
                })
            }
            "mtls" => match TlsSettings::from_config(cert_dir.as_deref(), config)? {
                Some(tls) => SecuritySettings::Mtls(tls),
                None => SecuritySettings::None,
            },
            other => return Err(anyhow!("unsupported grpc.mode '{other}'")),
        };

        Ok(Some(GrpcSettings {
            listen_addr: listen,
            security,
        }))
    }
}

impl TlsSettings {
    fn from_config(cert_dir: Option<&str>, config: &Config) -> Result<Option<Self>> {
        let cert = read_string(config, "grpc.cert_file");
        let key = read_string(config, "grpc.key_file");
        let client_ca = read_string(config, "grpc.client_ca_file")
            .or_else(|| read_string(config, "grpc.ca_file"));

        if cert.is_none() && key.is_none() && client_ca.is_none() {
            return Ok(None);
        }

        let cert = cert.ok_or_else(|| anyhow!("grpc.cert_file is required in mTLS mode"))?;
        let key = key.ok_or_else(|| anyhow!("grpc.key_file is required in mTLS mode"))?;
        let client_ca = client_ca.ok_or_else(|| {
            anyhow!("grpc.client_ca_file or grpc.ca_file is required in mTLS mode")
        })?;

        Ok(Some(TlsSettings {
            cert_path: resolve_path(cert_dir, cert),
            key_path: resolve_path(cert_dir, key),
            client_ca_path: resolve_path(cert_dir, client_ca),
        }))
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

async fn serve_with_tls(addr: SocketAddr, tls: Option<ServerTlsConfig>) -> Result<()> {
    let (mut reporter, health_service) = health_reporter();

    reporter
        .set_service_status("", ServingStatus::Serving)
        .await;
    reporter
        .set_service_status("flowgger", ServingStatus::Serving)
        .await;

    let mut server = Server::builder();
    if let Some(tls) = tls {
        server = server.tls_config(tls)?;
    }

    server
        .add_service(health_service)
        .serve(addr)
        .await
        .context("flowgger gRPC server failed")
}

async fn serve_with_spiffe(addr: SocketAddr, cfg: SpiffeSettings) -> Result<()> {
    let credentials = spiffe::load_server_credentials(&cfg.workload_socket, &cfg.trust_domain)
        .await
        .context("failed to load SPIFFE credentials for flowgger gRPC server")?;
    let mut updates = credentials.watch_updates();
    updates.borrow_and_update();

    loop {
        let (mut reporter, health_service) = health_reporter();
        reporter
            .set_service_status("", ServingStatus::Serving)
            .await;
        reporter
            .set_service_status("flowgger", ServingStatus::Serving)
            .await;

        let (identity, client_ca) = credentials.tls_materials()?;
        let tls = ServerTlsConfig::new()
            .identity(identity)
            .client_ca_root(client_ca);

        let mut shutdown_rx = updates.clone();
        let server_future = Server::builder()
            .tls_config(tls)?
            .add_service(health_service)
            .serve_with_shutdown(addr, async move {
                let _ = shutdown_rx.changed().await;
            });

        tokio::pin!(server_future);

        let mut reload = false;
        let mut channel_closed = false;

        tokio::select! {
            biased;
            res = updates.changed() => {
                match res {
                    Ok(_) => reload = true,
                    Err(_) => channel_closed = true,
                }
            }
            res = &mut server_future => {
                res.context("flowgger gRPC server encountered an error during SPIFFE serve")?;
                return Ok(());
            }
        }

        if reload {
            info!("SPIFFE update detected; reloading flowgger gRPC server identity");
            updates.borrow_and_update();
            server_future.await?;
            continue;
        }

        if channel_closed {
            server_future.await?;
            break;
        }
    }

    Ok(())
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
    fn spiffe_defaults_workload_socket() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "spiffe"
            trust_domain = "example.test"
        "#,
        );

        let settings = GrpcSettings::from_config(&config)
            .expect("config parsing failed")
            .expect("expected settings");

        match settings.security {
            SecuritySettings::Spiffe(spiffe) => {
                assert_eq!(spiffe.trust_domain, "example.test");
                assert_eq!(spiffe.workload_socket, DEFAULT_WORKLOAD_SOCKET);
            }
            other => panic!("expected SPIFFE security, got {other:?}"),
        }
    }

    #[test]
    fn spiffe_honors_custom_socket() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "spiffe"
            trust_domain = "example.test"
            workload_socket = "unix:/custom.sock"
        "#,
        );

        let settings = GrpcSettings::from_config(&config)
            .expect("config parsing failed")
            .expect("expected settings");

        match settings.security {
            SecuritySettings::Spiffe(spiffe) => {
                assert_eq!(spiffe.trust_domain, "example.test");
                assert_eq!(spiffe.workload_socket, "unix:/custom.sock");
            }
            other => panic!("expected SPIFFE security, got {other:?}"),
        }
    }

    #[test]
    fn spiffe_requires_trust_domain() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "spiffe"
        "#,
        );

        let err = GrpcSettings::from_config(&config).expect_err("expected failure");
        assert!(
            err.to_string().contains("trust_domain"),
            "error message should reference trust_domain: {err}"
        );
    }

    #[test]
    fn mtls_without_paths_disables_tls() {
        let config = load_config(
            r#"
            [grpc]
            listen_addr = "0.0.0.0:50044"
            mode = "mtls"
        "#,
        );

        let settings = GrpcSettings::from_config(&config)
            .expect("config parsing failed")
            .expect("expected settings");
        match settings.security {
            SecuritySettings::None => {}
            other => panic!("expected TLS to be disabled, got {other:?}"),
        }
    }
}
