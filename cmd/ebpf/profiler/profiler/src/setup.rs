use anyhow::{Context, Result};
use log::{info, warn, LevelFilter};
use std::net::SocketAddr;
use std::fs;

use crate::cli::CLI;
use crate::config::Config;

pub fn setup_logging_and_parse_args() -> Result<CLI> {
    let args = CLI::parse_args();
    
    // Setup logging based on CLI args
    let log_level = if args.is_debug_enabled() {
        LevelFilter::Debug
    } else {
        LevelFilter::Info
    };
    
    env_logger::Builder::from_default_env()
        .filter_level(log_level)
        .init();
    
    info!("ServiceRadar eBPF Profiler Service starting up");
    info!("Log level: {}", log_level);
    
    Ok(args)
}

pub fn handle_generate_config() -> Result<(), Box<dyn std::error::Error>> {
    let example_config = Config::example_toml();
    
    println!("# ServiceRadar eBPF Profiler Configuration");
    println!("# Save this content to 'profiler.toml' and modify as needed");
    println!();
    println!("{}", example_config);
    
    // Also write to profiler.toml.example
    if let Err(e) = fs::write("profiler.toml.example", example_config) {
        warn!("Could not write profiler.toml.example: {}", e);
    } else {
        info!("Example configuration written to profiler.toml.example");
    }
    
    Ok(())
}

pub fn load_configuration(args: &CLI) -> Result<Config> {
    Config::load(args.config.as_deref())
        .context("Failed to load configuration")
}

pub fn parse_bind_address(config: &Config) -> Result<SocketAddr> {
    let bind_addr = config.bind_address();
    
    bind_addr.parse::<SocketAddr>()
        .with_context(|| format!("Failed to parse bind address: {}", bind_addr))
}

pub fn log_configuration_info(config: &Config) {
    info!("Configuration loaded:");
    info!("  Server bind address: {}", config.bind_address());
    info!("  gRPC TLS enabled: {}", config.grpc_tls.is_some());
    info!("  Max concurrent sessions: {}", config.profiler.max_concurrent_sessions);
    info!("  Max session duration: {}s", config.profiler.max_session_duration_seconds);
    info!("  Max sampling frequency: {}Hz", config.profiler.max_frequency_hz);
    info!("  Chunk size: {} bytes", config.profiler.chunk_size_bytes);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_bind_address() {
        let config = Config {
            server: crate::config::ServerConfig {
                bind_address: "127.0.0.1".to_string(),
                port: 8080,
            },
            grpc_tls: None,
            profiler: crate::config::ProfilerConfig::default(),
        };
        
        let addr = parse_bind_address(&config).unwrap();
        assert_eq!(addr.ip().to_string(), "127.0.0.1");
        assert_eq!(addr.port(), 8080);
    }

    #[test]
    fn test_parse_bind_address_ipv6() {
        let config = Config {
            server: crate::config::ServerConfig {
                bind_address: "[::1]".to_string(), // IPv6 addresses need brackets
                port: 9090,
            },
            grpc_tls: None,
            profiler: crate::config::ProfilerConfig::default(),
        };
        
        let addr = parse_bind_address(&config).unwrap();
        assert_eq!(addr.ip().to_string(), "::1");
        assert_eq!(addr.port(), 9090);
    }

    #[test]
    fn test_parse_invalid_bind_address() {
        let config = Config {
            server: crate::config::ServerConfig {
                bind_address: "invalid_address".to_string(),
                port: 8080,
            },
            grpc_tls: None,
            profiler: crate::config::ProfilerConfig::default(),
        };
        
        let result = parse_bind_address(&config);
        assert!(result.is_err());
    }
}