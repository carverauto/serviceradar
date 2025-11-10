# config-bootstrap

Configuration bootstrap library for ServiceRadar Rust services.

This crate mirrors the functionality of Go's `pkg/config/bootstrap` to provide a unified config loading experience across all ServiceRadar components.

## Features

- **Load from disk**: Read JSON or TOML configuration files
- **KV overlay**: Merge configuration from NATS KV store
- **Sanitization**: Automatically filter sensitive fields before writing to KV
- **Auto-seeding**: Seed sanitized defaults to KV when missing
- **Watch support**: Monitor KV for configuration changes (partial implementation)

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
        kv_key: Some("config/my-service.toml".to_string()),
        seed_kv: true,
        watch_kv: false,
    };

    let mut bootstrap = Bootstrap::new(opts).await?;
    let config: MyConfig = bootstrap.load().await?;

    println!("Loaded config: {:?}", config);
    Ok(())
}
```

## Configuration Lifecycle

1. **Load from disk**: Read the config file specified in `config_path`
2. **Overlay KV**: If KV is available and the key exists, merge KV values on top
3. **Seed KV**: If KV key doesn't exist and `seed_kv` is true, write sanitized config to KV
4. **Watch** (optional): If `watch_kv` is true, monitor KV for changes

## Sanitization

Before writing configuration to KV, sensitive fields are automatically removed based on rules in `config/sanitization-rules.json`. This ensures secrets never leave the local filesystem.

For TOML configs, the following keys are dropped by default:
- `token`
- `secret`
- `password`
- `api_key` / `apiKey`
- `private_key` / `privateKey`
- Entire `[security]` table
- TLS credential paths in `[tls]` table

See `config/sanitization-rules.json` for the complete list.

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
       kv_key: Some("config/my-service.toml".to_string()),
       seed_kv: true,
       watch_kv: false,
   }).await?;
   let config: MyConfig = bootstrap.load().await?;
   ```

3. The service will now:
   - Load config from disk
   - Overlay KV values if present
   - Auto-seed sanitized config to KV if missing
   - Support future hot-reload via KV watch

## Architecture

This crate is designed to replace the shell-based `config-sync` wrapper currently used by Rust services (flowgger, trapd, otel, zen-consumer). Instead of running a separate Go binary before service startup, services can directly call this Rust library.

Benefits:
- **Native Rust**: No cross-language binary dependencies
- **Testable**: Logic lives in Rust code with proper unit tests
- **Consistent**: Same sanitization rules as Go services
- **Maintainable**: Changes to config logic don't require rebuilding multiple binaries

## Testing

```bash
cargo test -p config-bootstrap
```

## License

Apache-2.0
