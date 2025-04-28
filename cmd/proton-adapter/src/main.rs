mod adapter;
mod processor;
mod processors;
mod models;

use adapter::ProtonAdapter;
use clap::Parser;
use std::error::Error;

/// ServiceRadar Proton Adapter
#[derive(Parser, Debug)]
#[clap(author, version, about)]
struct Args {
    /// Proton URL
    #[clap(long, env = "PROTON_URL", default_value = "http://localhost:8463")]
    proton_url: String,

    /// Address to listen on
    #[clap(long, env = "LISTEN_ADDR", default_value = "[::1]:50052")]
    listen_addr: String,

    /// Whether to forward requests to core
    #[clap(long, env = "FORWARD_TO_CORE", default_value = "true")]
    forward_to_core: bool,

    /// Core service address
    #[clap(long, env = "CORE_ADDRESS")]
    core_address: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init();

    let args = Args::parse();

    log::info!("Starting Proton adapter on {}", args.listen_addr);
    log::info!("Proton URL: {}", args.proton_url);
    log::info!("Forward to core: {}", args.forward_to_core);

    // Create and start the adapter
    let adapter = ProtonAdapter::new(
        args.proton_url,
        args.forward_to_core,
        args.core_address
    ).await?;

    // Start gRPC server
    adapter.serve(args.listen_addr).await?;

    Ok(())
}