use profiler::setup::{setup_logging_and_parse_args, handle_generate_config, load_configuration, parse_bind_address, log_configuration_info};
use profiler::server::{create_profiler, start_server};
use profiler::run_standalone_profiling;
use log::info;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;
    
    if args.generate_config {
        return handle_generate_config();
    }
    
    // Check if we're in standalone profiling mode
    if args.is_standalone_mode() {
        // Validate standalone arguments
        if let Err(e) = args.validate_standalone() {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        
        let pid = args.pid.unwrap(); // Safe because is_standalone_mode() checks this
        info!("Starting standalone profiling mode for PID {}", pid);
        
        run_standalone_profiling(
            pid,
            args.duration,
            args.frequency,
            args.output_file,
            args.format,
            args.tui,
        ).await?;
        return Ok(());
    }
    
    // Server mode - existing logic
    let config = load_configuration(&args)?;
    let addr = parse_bind_address(&config)?;
    
    log_configuration_info(&config);
    
    let profiler = create_profiler().await?;
    
    start_server(addr, profiler).await
}
