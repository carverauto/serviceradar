use profiler::setup::{setup_logging_and_parse_args, handle_generate_config, load_configuration, parse_bind_address, log_configuration_info};
use profiler::server::{create_profiler, start_server};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;
    
    if args.generate_config {
        return handle_generate_config();
    }
    
    let config = load_configuration(&args)?;
    let addr = parse_bind_address(&config)?;
    
    log_configuration_info(&config);
    
    let profiler = create_profiler().await?;
    
    start_server(addr, profiler).await
}
