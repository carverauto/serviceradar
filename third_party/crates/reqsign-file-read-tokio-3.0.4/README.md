# reqsign-file-read-tokio

Tokio-based file reading implementation for reqsign.

---

This crate provides `TokioFileRead`, an async file reader that implements the `FileRead` trait from `reqsign_core` using Tokio's file system operations.

## Quick Start

```rust
use reqsign_core::Context;
use reqsign_file_read_tokio::TokioFileRead;

// Create a context with Tokio file reader
let ctx = Context::new(
    TokioFileRead::default(),
    http_client, // Your HTTP client
);

// Read files asynchronously
let content = ctx.file_read("/path/to/file").await?;
```

## Features

- **Async File I/O**: Leverages Tokio's async file system operations
- **Zero Configuration**: Works out of the box with sensible defaults
- **Lightweight**: Minimal dependencies, only what's needed

## Use Cases

This crate is essential when:
- Loading credentials from file system (e.g., `~/.aws/credentials`)
- Reading service account keys (e.g., Google Cloud service account JSON)
- Accessing configuration files for various cloud providers

## Examples

### Reading Credentials

Check out the [read_credentials example](examples/read_credentials.rs) to see how to read credential files:

```bash
cargo run --example read_credentials -- ~/.aws/credentials
```

### Integration with Services

```rust
use reqsign_core::{Context, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

// Create context with Tokio file reader
let ctx = Context::new(
    TokioFileRead::default(),
    ReqwestHttpSend::default(),
);

// Use with any service that needs file access
let signer = Signer::new(ctx, loader, builder);
```

## Requirements

- Tokio runtime with `fs` feature enabled
- Compatible with all reqsign service implementations

## License

Licensed under [Apache License, Version 2.0](./LICENSE).