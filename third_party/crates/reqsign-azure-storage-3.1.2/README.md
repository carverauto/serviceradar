# reqsign-azure-storage

Azure Storage signing support for reqsign.

This crate signs requests for Blob, File, Queue, and Table Storage. It supports
shared key, SAS token, and Azure AD bearer token credentials.

## Quick Start

```rust
use anyhow::Result;
use reqsign_azure_storage::{DefaultCredentialProvider, RequestSigner};
use reqsign_core::{Context, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

#[tokio::main]
async fn main() -> Result<()> {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default());

    let signer = Signer::new(
        ctx,
        DefaultCredentialProvider::new(),
        RequestSigner::new(),
    );

    let mut req = http::Request::get(
        "https://mystorageaccount.blob.core.windows.net/container/blob",
    )
    .body(())
    .unwrap()
    .into_parts()
    .0;

    signer.sign(&mut req, None).await?;
    Ok(())
}
```

## Default Credential Chain

`DefaultCredentialProvider::new()` uses this chain:

1. `env`
2. `azure_cli` (`non-wasm32` only)
3. `client_certificate` (`non-wasm32` only)
4. `client_secret`
5. `azure_pipelines`
6. `workload_identity`
7. `imds`

Use `DefaultCredentialProvider::builder()` to customize slot participation.

```rust
use reqsign_azure_storage::{
    ClientSecretCredentialProvider, DefaultCredentialProvider,
};

let provider = DefaultCredentialProvider::builder()
    .no_env()
    .client_secret(
        ClientSecretCredentialProvider::new().with_tenant_id("tenant-id"),
    )
    .no_imds()
    .build();
```

## Environment Variables

Shared key:

```bash
export AZURE_STORAGE_ACCOUNT_NAME=mystorageaccount
export AZURE_STORAGE_ACCOUNT_KEY=base64encodedkey==
```

SAS token:

```bash
export AZURE_STORAGE_SAS_TOKEN="sv=2021-06-08&ss=b&srt=sco&sp=rwdlacx..."
```

Client secret:

```bash
export AZURE_TENANT_ID=tenant-id
export AZURE_CLIENT_ID=client-id
export AZURE_CLIENT_SECRET=client-secret
```

## Using Specific Providers

Use a single provider directly when you do not want the default chain:

```rust
use reqsign_azure_storage::{EnvCredentialProvider, StaticCredentialProvider};

let env_provider = EnvCredentialProvider::new();

let static_provider = StaticCredentialProvider::new_shared_key(
    "mystorageaccount",
    "base64encodedkey==",
);
```

## Examples

Run the example:

```bash
cargo run --example blob_storage
```
