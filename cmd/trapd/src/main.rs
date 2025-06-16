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
use std::net::SocketAddr;
use tokio::net::UdpSocket;

mod config;
use config::Config;

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

    let socket = UdpSocket::bind(&cfg.listen_addr).await?;

    let nats_client = async_nats::connect(&cfg.nats_url).await?;
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
