extern crate flowgger;

use clap::{Arg, Command};
use std::io::{stderr, Write};
use std::fs;
use toml::Value;

mod grpc;

const DEFAULT_CONFIG_FILE: &str = "flowgger.toml";
const FLOWGGER_VERSION_STRING: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let matches = Command::new("Flowgger")
        .version(FLOWGGER_VERSION_STRING)
        .about("A fast, simple and lightweight data collector")
        .arg(
            Arg::new("config_file")
                .help("Configuration file")
                .value_name("FILE")
                .index(1),
        )
        .get_matches();
    let config_file = matches
        .get_one::<String>("config_file")
        .map(|s| s.as_ref())
        .unwrap_or(DEFAULT_CONFIG_FILE);
    let _ = writeln!(stderr(), "Flowgger {}", FLOWGGER_VERSION_STRING);

    if let Ok(content) = fs::read_to_string(config_file) {
        if let Ok(cfg) = content.parse::<Value>() {
            if let Some(addr_val) = cfg.get("grpc").and_then(|s| s.get("listen_addr")).and_then(|v| v.as_str()) {
                let addr: std::net::SocketAddr = addr_val.parse().expect("invalid grpc listen_addr");
                let cert = cfg.get("grpc").and_then(|s| s.get("cert_file")).and_then(|v| v.as_str()).map(|s| s.to_string());
                let key = cfg.get("grpc").and_then(|s| s.get("key_file")).and_then(|v| v.as_str()).map(|s| s.to_string());
                let ca = cfg.get("grpc").and_then(|s| s.get("ca_file")).and_then(|v| v.as_str()).map(|s| s.to_string());
                std::thread::spawn(move || {
                    let rt = tokio::runtime::Builder::new_multi_thread()
                        .enable_all()
                        .build()
                        .expect("tokio runtime");
                    rt.block_on(grpc::start_grpc_server(addr, cert, key, ca))
                        .expect("gRPC server failed");
                });
            }
        }
    }

    flowgger::start(config_file)
}
