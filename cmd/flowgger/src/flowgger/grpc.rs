use std::{fs, net::SocketAddr, thread};

use log::{error, info, warn};
use tonic::transport::{Certificate, Identity, Server, ServerTlsConfig};
use tonic_health::{server::health_reporter, ServingStatus};

use super::config::Config;

pub fn maybe_spawn(config: &Config) {
    let settings = match GrpcSettings::from_config(config) {
        Ok(Some(settings)) => settings,
        Ok(None) => return,
        Err(err) => {
            error!("flowgger gRPC disabled: invalid configuration: {err}");
            return;
        }
    };

    info!(
        "flowgger gRPC configuration detected for {}, preparing server",
        settings.listen_addr
    );

    if let Err(err) = spawn_server(settings) {
        error!("flowgger gRPC disabled: failed to spawn server: {err}");
    }
}

fn spawn_server(settings: GrpcSettings) -> Result<(), Box<dyn std::error::Error>> {
    thread::Builder::new()
        .name("flowgger-grpc".into())
        .spawn(move || {
            info!("flowgger gRPC server starting on {}", settings.listen_addr);
            if let Err(err) = run_server(settings) {
                error!("flowgger gRPC server exited: {err}");
            }
        })?;

    Ok(())
}

fn run_server(settings: GrpcSettings) -> Result<(), Box<dyn std::error::Error>> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_io()
        .enable_time()
        .build()?;

    rt.block_on(async move {
        let addr: SocketAddr = settings.listen_addr.parse()?;
        let (mut reporter, health_service) = health_reporter();

        // Mark both the overall service ("") and a named service as serving so clients
        // using either convention receive a healthy status.
        reporter
            .set_service_status("", ServingStatus::Serving)
            .await;
        reporter
            .set_service_status("flowgger", ServingStatus::Serving)
            .await;

        let mut server = Server::builder();
        match settings.tls.tls_config()? {
            Some(tls) => {
                server = server.tls_config(tls)?;
            }
            None => {
                warn!("flowgger gRPC server starting without TLS; clients must allow plaintext");
            }
        }

        server
            .add_service(health_service)
            .serve(addr)
            .await
            .map_err(|err| Box::new(err) as Box<dyn std::error::Error>)
    })
}

struct GrpcSettings {
    listen_addr: String,
    tls: TlsSettings,
}

struct TlsSettings {
    cert_file: Option<String>,
    key_file: Option<String>,
    ca_file: Option<String>,
    client_ca_file: Option<String>,
}

impl TlsSettings {
    fn tls_config(&self) -> Result<Option<ServerTlsConfig>, Box<dyn std::error::Error>> {
        match (&self.cert_file, &self.key_file) {
            (None, None) => return Ok(None),
            (Some(_), Some(_)) => {}
            _ => {
                return Err(
                    "grpc.cert_file and grpc.key_file must both be provided when enabling TLS"
                        .into(),
                )
            }
        }

        let cert_path = self.cert_file.as_ref().unwrap();
        let key_path = self.key_file.as_ref().unwrap();

        let client_ca_path = self
            .client_ca_file
            .as_ref()
            .or(self.ca_file.as_ref())
            .ok_or_else(|| "grpc.client_ca_file or grpc.ca_file is required when TLS is enabled")?;

        let identity = Identity::from_pem(fs::read(cert_path)?, fs::read(key_path)?);
        let client_ca = Certificate::from_pem(fs::read(client_ca_path)?);

        let tls = ServerTlsConfig::new()
            .identity(identity)
            .client_ca_root(client_ca);

        Ok(Some(tls))
    }
}

impl GrpcSettings {
    fn from_config(config: &Config) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let listen = match config.lookup("grpc.listen_addr") {
            Some(value) => value
                .as_str()
                .ok_or("grpc.listen_addr must be a string")?
                .trim()
                .to_string(),
            None => return Ok(None),
        };

        if listen.is_empty() {
            return Ok(None);
        }

        let tls = TlsSettings {
            cert_file: config
                .lookup("grpc.cert_file")
                .and_then(|v| v.as_str().map(|s| s.trim().to_string()))
                .filter(|s| !s.is_empty()),
            key_file: config
                .lookup("grpc.key_file")
                .and_then(|v| v.as_str().map(|s| s.trim().to_string()))
                .filter(|s| !s.is_empty()),
            ca_file: config
                .lookup("grpc.ca_file")
                .and_then(|v| v.as_str().map(|s| s.trim().to_string()))
                .filter(|s| !s.is_empty()),
            client_ca_file: config
                .lookup("grpc.client_ca_file")
                .and_then(|v| v.as_str().map(|s| s.trim().to_string()))
                .filter(|s| !s.is_empty()),
        };

        Ok(Some(GrpcSettings {
            listen_addr: listen,
            tls,
        }))
    }
}
