# reqsign-azure-storage

Azure Storage signing implementation for reqsign.

---

This crate provides comprehensive signing support for Azure Storage services including Blob Storage, File Storage, Queue Storage, and Table Storage.

## Quick Start

```rust
use reqsign_azure_storage::{Builder, Config, DefaultLoader};
use reqsign_core::{Context, Signer};

// Create context and signer
let ctx = Context::default();
let config = Config::default()
    .account_name("mystorageaccount")
    .from_env();
let loader = DefaultLoader::new(config);
let builder = Builder::new();
let signer = Signer::new(ctx, loader, builder);

// Sign requests
let mut req = http::Request::get("https://mystorageaccount.blob.core.windows.net/container/blob")
    .body(())
    .unwrap()
    .into_parts()
    .0;

signer.sign(&mut req, None).await?;
```

## Features

- **Multiple Auth Methods**: Shared Key, SAS tokens, and Azure AD
- **All Storage Services**: Blob, File, Queue, and Table storage
- **Managed Identity**: Automatic authentication on Azure services
- **Flexible Configuration**: Environment variables, config files, or code

## Authentication Methods

### 1. Shared Key (Storage Account Key)

```bash
export AZURE_STORAGE_ACCOUNT_NAME=mystorageaccount
export AZURE_STORAGE_ACCOUNT_KEY=base64encodedkey==
```

```rust
let config = Config::default()
    .account_name("mystorageaccount")
    .account_key("base64encodedkey==");
```

### 2. SAS Token

```bash
export AZURE_STORAGE_SAS_TOKEN=sv=2021-06-08&ss=b&srt=sco&sp=rwdlacx&se=2024-12-31T23:59:59Z&...
```

```rust
let config = Config::default()
    .account_name("mystorageaccount")
    .sas_token("sv=2021-06-08&ss=b...");
```

### 3. Azure AD / OAuth

```bash
export AZURE_CLIENT_ID=your-client-id
export AZURE_CLIENT_SECRET=your-client-secret
export AZURE_TENANT_ID=your-tenant-id
```

```rust
let config = Config::default()
    .account_name("mystorageaccount")
    .client_id("client-id")
    .client_secret("client-secret")
    .tenant_id("tenant-id");
```

### 4. Managed Identity

Automatically used when running on Azure services:

```rust
// No explicit credentials needed
let config = Config::default()
    .account_name("mystorageaccount");
```

## Storage Services

### Blob Storage

```rust
// List containers
let req = http::Request::get("https://account.blob.core.windows.net/?comp=list")
    .header("x-ms-version", "2021-12-02")
    .body(())?;

// Get blob
let req = http::Request::get("https://account.blob.core.windows.net/container/blob.txt")
    .header("x-ms-version", "2021-12-02")
    .body(())?;

// Upload blob
let req = http::Request::put("https://account.blob.core.windows.net/container/blob.txt")
    .header("x-ms-version", "2021-12-02")
    .header("x-ms-blob-type", "BlockBlob")
    .body(content)?;
```

### File Storage

```rust
// List shares
let req = http::Request::get("https://account.file.core.windows.net/?comp=list")
    .header("x-ms-version", "2021-12-02")
    .body(())?;

// Get file
let req = http::Request::get("https://account.file.core.windows.net/share/dir/file.txt")
    .header("x-ms-version", "2021-12-02")
    .body(())?;
```

### Queue Storage

```rust
// List queues
let req = http::Request::get("https://account.queue.core.windows.net/?comp=list")
    .header("x-ms-version", "2021-12-02")
    .body(())?;

// Get messages
let req = http::Request::get("https://account.queue.core.windows.net/myqueue/messages")
    .header("x-ms-version", "2021-12-02")
    .body(())?;
```

### Table Storage

```rust
// Query entities
let req = http::Request::get("https://account.table.core.windows.net/mytable()")
    .header("x-ms-version", "2021-12-02")
    .header("Accept", "application/json")
    .body(())?;
```

## Examples

Check out the examples directory:
- [Blob storage operations](examples/blob_storage.rs) - Complete blob storage examples

```bash
cargo run --example blob_storage
```

## Credential Loading Order

The `DefaultLoader` tries credentials in this order:

1. SAS Token (if provided)
2. Shared Key (if provided)
3. Azure AD Client Credentials
4. Managed Identity (on Azure services)
5. Azure CLI credentials

## Advanced Configuration

### Custom Authority Host

```rust
let config = Config::default()
    .account_name("mystorageaccount")
    .authority_host("https://login.microsoftonline.com");
```

### Specific Credential Type

```rust
// Force Shared Key only
use reqsign_azure_storage::ClientSecretLoader;

let loader = ClientSecretLoader::new(config);
```

## License

Licensed under [Apache License, Version 2.0](./LICENSE).