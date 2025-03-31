use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::time::Duration;

/// Security configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    pub tls_enabled: bool,
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

/// Configuration for individual targets to test
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetConfig {
    pub name: String,
    pub address: String,
    pub port: u16,
    pub protocol: String, // "tcp" or "udp"
    pub reverse: bool,
    pub bandwidth: u64,  // in bytes/sec
    pub duration: f64,   // in seconds
    pub parallel: u32,
    pub length: u32,     // buffer size
    pub omit: u32,       // seconds to omit from start
    pub no_delay: bool,
    pub send_buffer: u32,
    pub receive_buffer: u32,
    pub send_interval: f64,
    pub poll_interval: u64,  // in seconds
}

/// Configuration for the rperf gRPC checker
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub listen_addr: String,
    pub security: Option<SecurityConfig>,
    pub targets: Vec<TargetConfig>,
    pub default_poll_interval: u64, // in seconds
}

impl Config {
    /// Load configuration from a file
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path)
            .context("Failed to read config file")?;
            
        let config: Config = serde_json::from_str(&content)
            .context("Failed to parse config file")?;
            
        config.validate()?;
        
        Ok(config)
    }
    
    /// Validate the configuration
    pub fn validate(&self) -> Result<()> {
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        
        if self.default_poll_interval == 0 {
            anyhow::bail!("default_poll_interval must be greater than 0");
        }
        
        for target in &self.targets {
            if target.address.is_empty() {
                anyhow::bail!("target address is required");
            }
            
            if target.protocol != "tcp" && target.protocol != "udp" {
                anyhow::bail!("protocol must be 'tcp' or 'udp'");
            }
            
            if target.poll_interval == 0 {
                anyhow::bail!("target poll_interval must be greater than 0");
            }
        }
        
        // Check TLS configuration if enabled
        if let Some(security) = &self.security {
            if security.tls_enabled {
                if security.cert_file.is_none() || security.key_file.is_none() {
                    anyhow::bail!("When TLS is enabled, cert_file and key_file are required");
                }
                if security.ca_file.is_none() {
                    anyhow::bail!("When TLS is enabled, ca_file is required for mTLS");
                }
            }
        }
        
        Ok(())
    }
    
    /// Get poll interval for a target, or use default if not specified
    pub fn get_poll_interval(&self, target: &TargetConfig) -> Duration {
        Duration::from_secs(target.poll_interval.max(1))
    }
}