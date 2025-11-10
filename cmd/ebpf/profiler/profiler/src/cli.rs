use clap::Parser;

#[derive(Parser)]
#[command(name = "profiler")]
#[command(about = "ServiceRadar eBPF Profiler Service - can run as gRPC server or standalone CLI")]
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

    /// gRPC server bind address (server mode)
    #[arg(short = 'b', long = "bind", value_name = "ADDRESS")]
    pub bind_address: Option<String>,

    /// Profile a specific process ID (standalone mode)
    #[arg(short = 'p', long = "pid", value_name = "PID")]
    pub pid: Option<i32>,

    /// Output file for profiling results (standalone mode)
    #[arg(short = 'f', long = "file", value_name = "FILE")]
    pub output_file: Option<String>,

    /// Duration to profile in seconds (standalone mode, default: 30)
    #[arg(
        short = 't',
        long = "duration",
        value_name = "SECONDS",
        default_value = "30"
    )]
    pub duration: i32,

    /// Sampling frequency in Hz (standalone mode, default: 99)
    #[arg(long = "frequency", value_name = "HZ", default_value = "99")]
    pub frequency: i32,

    /// Output format for standalone mode
    #[arg(long = "format", value_name = "FORMAT", default_value = "pprof")]
    pub format: OutputFormat,

    /// Display interactive TUI flamegraph instead of writing to file
    #[arg(long = "tui")]
    pub tui: bool,
}

#[derive(Clone, Debug)]
pub enum OutputFormat {
    Pprof,
    FlameGraph,
    Json,
}

impl std::str::FromStr for OutputFormat {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "pprof" => Ok(OutputFormat::Pprof),
            "flamegraph" | "flame" => Ok(OutputFormat::FlameGraph),
            "json" => Ok(OutputFormat::Json),
            _ => Err(format!(
                "Invalid format '{}'. Valid formats: pprof, flamegraph, json",
                s
            )),
        }
    }
}

impl CLI {
    pub fn parse_args() -> Self {
        Self::parse()
    }

    /// Returns true if debug logging should be enabled
    pub fn is_debug_enabled(&self) -> bool {
        self.debug || self.verbose
    }

    /// Returns true if we're in standalone profiling mode
    pub fn is_standalone_mode(&self) -> bool {
        self.pid.is_some()
    }

    /// Validate CLI arguments for standalone mode
    pub fn validate_standalone(&self) -> Result<(), String> {
        if let Some(pid) = self.pid {
            if pid <= 0 {
                return Err("PID must be a positive integer".to_string());
            }
        }

        if self.duration <= 0 || self.duration > 300 {
            return Err("Duration must be between 1 and 300 seconds".to_string());
        }

        if self.frequency <= 0 || self.frequency > 1000 {
            return Err("Frequency must be between 1 and 1000 Hz".to_string());
        }

        Ok(())
    }
}
