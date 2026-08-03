# reqsign-http-send-reqwest

Reqwest-based HTTP client implementation for reqsign.

---

This crate provides `ReqwestHttpSend`, an HTTP client that implements the `HttpSend` trait from `reqsign_core` using the popular reqwest library.

## Quick Start

```rust
use reqsign_core::Context;
use reqsign_http_send_reqwest::ReqwestHttpSend;

// Use with default configuration
let ctx = Context::new(
    file_reader,
    ReqwestHttpSend::default(),
);

// Or with custom client configuration
let client = reqwest::Client::builder()
    .timeout(std::time::Duration::from_secs(30))
    .build()
    .unwrap();

let ctx = Context::new(
    file_reader,
    ReqwestHttpSend::new(client),
);
```

## Features

- **Full reqwest compatibility**: Use all of reqwest's powerful features
- **Seamless integration**: Automatic conversion between `http` and `reqwest` types
- **Customizable**: Configure timeouts, proxies, TLS settings, and more
- **Async/await**: Built for modern async Rust applications

## Configuration Options

```rust
use reqwest::Client;
use reqsign_http_send_reqwest::ReqwestHttpSend;

let client = Client::builder()
    // Timeouts
    .timeout(Duration::from_secs(30))
    .connect_timeout(Duration::from_secs(10))
    
    // Connection pooling
    .pool_max_idle_per_host(10)
    .pool_idle_timeout(Duration::from_secs(90))
    
    // HTTP settings
    .user_agent("my-app/1.0")
    .default_headers(headers)
    
    // Proxy configuration
    .proxy(reqwest::Proxy::https("https://proxy.example.com")?)
    
    // TLS configuration
    .danger_accept_invalid_certs(false)
    .min_tls_version(reqwest::tls::Version::TLS_1_2)
    
    .build()?;

let http_send = ReqwestHttpSend::new(client);
```

## Examples

### Custom Client Configuration

Check out the [custom_client example](examples/custom_client.rs) to see various configuration options:

```bash
cargo run --example custom_client
```

### Integration with Services

```rust
use reqsign_core::{Context, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

// Create context for cloud service clients
let ctx = Context::new(
    TokioFileRead::default(),
    ReqwestHttpSend::default(),
);

// Use with any reqsign service
let signer = Signer::new(ctx, loader, builder);
```

## Why reqwest?

- **Mature and stable**: One of the most popular HTTP clients in the Rust ecosystem
- **Feature-rich**: Supports proxies, cookies, redirect policies, and more
- **Well-maintained**: Regular updates and security patches
- **Extensive ecosystem**: Compatible with many Rust libraries and frameworks

## License

Licensed under [Apache License, Version 2.0](./LICENSE).