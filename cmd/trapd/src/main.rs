/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use anyhow::Result;
use clap::Parser;
use env_logger::Env;
use log::{info, warn};
use serde::Serialize;
use std::{net::SocketAddr, path::PathBuf};
use tokio::net::UdpSocket;

use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

mod config;
use config::Config;

pub mod monitoring {
    tonic::include_proto!("monitoring");
}
use monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

#[derive(Parser, Debug)]
#[command(name = "serviceradar-trapd")]
#[command(about = "ServiceRadar SNMP Trap Receiver", long_about = None)]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "TRAPD_CONFIG")]
    config: String,
}

#[derive(Serialize)]
struct Varbind {
    oid: String,
    value: String,
}

#[derive(Serialize)]
struct TrapMessage {
    source: String,
    version: String,
    community: String,
    varbinds: Vec<Varbind>,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    info!("Starting trap receiver on {}", cfg.listen_addr);

    if cfg.grpc_listen_addr.is_some() {
        let grpc_cfg = cfg.clone();
        tokio::spawn(async move {
            if let Err(e) = start_grpc_server(grpc_cfg).await {
                warn!("gRPC server error: {e}");
            }
        });
    }

    let socket = UdpSocket::bind(&cfg.listen_addr).await?;

    let nats_client = if let Some(sec) = &cfg.security {
        let mut opts = async_nats::ConnectOptions::new();
        if let Some(ca) = &sec.ca_file {
            opts = opts.add_root_certificates(PathBuf::from(ca));
        }
        if let (Some(cert), Some(key)) = (&sec.cert_file, &sec.key_file) {
            opts = opts.add_client_certificate(PathBuf::from(cert), PathBuf::from(key));
        }
        opts.connect(&cfg.nats_url).await?
    } else {
        async_nats::connect(&cfg.nats_url).await?
    };
    let js = async_nats::jetstream::new(nats_client);

    let mut buf = vec![0u8; 65535];
    loop {
        let (len, addr) = socket.recv_from(&mut buf).await?;
        let data = &buf[..len];
        match snmp2::Pdu::from_bytes(data) {
            Ok(pdu) => {
                let msg = build_message(&pdu, addr);
                let payload = serde_json::to_vec(&msg)?;
                if let Err(e) = js.publish(cfg.subject.clone(), payload.into()).await?.await {
                    warn!("Failed to publish trap: {e}");
                }
            }
            Err(e) => {
                warn!("Failed to parse SNMP trap from {addr}: {e}");
            }
        }
    }
}

fn build_message(pdu: &snmp2::Pdu<'_>, addr: SocketAddr) -> TrapMessage {
    let version = match pdu.version() {
        Ok(v) => format!("{:?}", v),
        Err(_) => "unknown".to_string(),
    };
    let community = String::from_utf8_lossy(pdu.community).into_owned();
    let mut varbinds = Vec::new();
    for (oid, value) in pdu.varbinds.clone() {
        varbinds.push(Varbind {
            oid: format!("{}", oid),
            value: format!("{:?}", value),
        });
    }
    TrapMessage {
        source: addr.to_string(),
        version,
        community,
        varbinds,
    }
}

#[derive(Debug, Default)]
struct TrapdAgentService;

#[tonic::async_trait]
impl AgentService for TrapdAgentService {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        let start = std::time::Instant::now();
        let msg = serde_json::json!({
            "status": "operational",
            "message": "trapd is operational",
        });
        let data = serde_json::to_vec(&msg).unwrap_or_default();
        Ok(Response::new(monitoring::StatusResponse {
            available: true,
            message: data,
            service_name: req.service_name,
            service_type: req.service_type,
            response_time: start.elapsed().as_nanos() as i64,
            agent_id: req.agent_id,
            poller_id: req.poller_id,
        }))
    }
}

async fn start_grpc_server(cfg: Config) -> Result<()> {
    let addr: std::net::SocketAddr = match cfg.grpc_listen_addr {
        Some(a) => a.parse()?,
        None => return Ok(()),
    };

    let service = TrapdAgentService::default();
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<TrapdAgentService>>()
        .await;

    let reflection_service = ReflectionBuilder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
        .build()?;

    let mut server_builder = Server::builder();
    if let Some(sec) = &cfg.grpc_security {
        if let (Some(cert), Some(key), Some(ca)) = (&sec.cert_file, &sec.key_file, &sec.ca_file) {
            let cert = std::fs::read_to_string(cert)?;
            let key = std::fs::read_to_string(key)?;
            let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());
            let ca_cert = std::fs::read_to_string(ca)?;
            let ca = Certificate::from_pem(ca_cert.as_bytes());
            let tls = ServerTlsConfig::new().identity(identity).client_ca_root(ca);
            server_builder = server_builder.tls_config(tls)?;
        }
    }

    server_builder
        .add_service(health_service)
        .add_service(AgentServiceServer::new(service))
        .add_service(reflection_service)
        .serve(addr)
        .await?;

    Ok(())
}
