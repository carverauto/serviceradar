use clap::Parser;

#[derive(Parser)]
#[command(name = "profiler")]
#[command(about = "ServiceRadar eBPF Profiler Service")]
#[command(version)]
pub struct CLI {
    /// Path to configuration file
    #[arg(short = 'c', long = "config", value_name = "FILE")]
    pub config: Option<String>,
    
    /// Generate example configuration file
    #[arg(long = "generate-config")]
    pub generate_config: bool,
    
    /// Enable debug logging
    #[arg(short = 'd', long = "debug")]
    pub debug: bool,
    
    /// Enable verbose logging (same as debug)
    #[arg(short = 'v', long = "verbose")]
    pub verbose: bool,
    
    /// gRPC server bind address
    #[arg(short = 'b', long = "bind", value_name = "ADDRESS")]
    pub bind_address: Option<String>,
}

impl CLI {
    pub fn parse_args() -> Self {
        Self::parse()
    }
    
    /// Returns true if debug logging should be enabled
    pub fn is_debug_enabled(&self) -> bool {
        self.debug || self.verbose
    }
}