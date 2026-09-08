# config-bootstrap

Configuration bootstrap library for ServiceRadar Rust services.

This crate mirrors the file-based portion of Go's `pkg/config/bootstrap` to provide a unified config loading experience across ServiceRadar components.

## Features

- **Load from disk**: Read JSON or TOML configuration files
- **Pinned overlay**: Apply a filesystem overlay that always wins over defaults (for sensitive overrides)

## Usage

```rust
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct MyConfig {
    listen_addr: String,
    log_level: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let opts = BootstrapOptions {
        service_name: "my-service".to_string(),
        config_path: "/etc/serviceradar/my-service.toml".to_string(),
        format: ConfigFormat::Toml,
        pinned_path: config_bootstrap::pinned_path_from_env(),
    };

    let mut bootstrap = Bootstrap::new(opts).await?;
    let config: MyConfig = bootstrap.load().await?;

    println!("Loaded config: {:?}", config);
    Ok(())
}
```

## Configuration Lifecycle

1. **Load from disk**: Read the config file specified in `config_path`
2. **Apply pinned overlay**: If `pinned_path` is set, overlay it last so it wins over defaults

## Integration with Existing Services

To integrate this crate into an existing Rust service:

1. Add dependency to `Cargo.toml`:
   ```toml
   [dependencies]
   config-bootstrap = { path = "../../rust/config-bootstrap" }
   ```

2. Replace manual config loading with bootstrap:
   ```rust
   // Before:
   let config: MyConfig = toml::from_str(&std::fs::read_to_string(path)?)?;

   // After:
   let mut bootstrap = Bootstrap::new(BootstrapOptions {
       service_name: "my-service".to_string(),
       config_path: path.to_string(),
       format: ConfigFormat::Toml,
       pinned_path: config_bootstrap::pinned_path_from_env(),
   }).await?;
   let config: MyConfig = bootstrap.load().await?;
   ```

3. The service will now:
   - Load config from disk
   - Apply pinned overrides if provided

## Architecture

This crate provides a single, testable Rust path for config loading (formerly handled by a Go KV bootstrapper for some services). It avoids cross-language binary dependencies and keeps config behavior consistent with file-based ServiceRadar services.

## Testing

```bash
cargo test -p config-bootstrap
```

## License

Apache-2.0
