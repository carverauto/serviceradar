# reqsign-aws-v4

AWS SigV4 signing implementation for `reqsign`.

## Quick Start

```rust,no_run
use reqsign_aws_v4::{DefaultCredentialProvider, RequestSigner};
use reqsign_core::{Context, OsEnv, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let signer = Signer::new(
        ctx,
        DefaultCredentialProvider::new(),
        RequestSigner::new("s3", "us-east-1"),
    );

    let mut req = http::Request::get("https://s3.amazonaws.com/mybucket/mykey")
        .body(())
        .unwrap()
        .into_parts()
        .0;

    signer.sign(&mut req, None).await?;
    Ok(())
}
```

## Default Credential Chain

`DefaultCredentialProvider::new()` builds the documented AWS default chain:

1. `env`
2. `profile`
3. `sso`
4. `web_identity`
5. `process`
6. `ecs`
7. `imds`

On `wasm32`, the non-portable `sso` and `process` slots are not available.

## Customize Slots

Use `DefaultCredentialProvider::builder()` to replace or remove individual slots.
Each slot is represented by `Option<T>` internally: `slot(provider)` enables it,
`no_slot()` removes it, and `build()` only pushes `Some(...)` slots into the
chain.

```rust,no_run
use reqsign_aws_v4::{DefaultCredentialProvider, ProfileCredentialProvider};

let provider = DefaultCredentialProvider::builder()
    .no_env()
    .profile(ProfileCredentialProvider::new().with_profile("production"))
    .no_imds()
    .build();
```

For advanced composition, use `DefaultCredentialProvider::with_chain(...)` or
prepend a higher-priority source with `DefaultCredentialProvider::push_front(...)`.

## Examples

- [S3 signing example](examples/s3_sign.rs)
- [DynamoDB signing example](examples/dynamodb_sign.rs)
- [S3 Express signing example](examples/s3_express_sign.rs)
