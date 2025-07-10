use clap::Parser;

#[derive(Parser)]
#[command(name = "otel")]
#[command(about = "ServiceRadar OpenTelemetry Collector")]
#[command(version)]
pub struct Cli {
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
}

impl Cli {
    pub fn parse_args() -> Self {
        Self::parse()
    }
    
    /// Returns true if debug logging should be enabled
    pub fn is_debug_enabled(&self) -> bool {
        self.debug || self.verbose
    }
}