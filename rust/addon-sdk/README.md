# addon-sdk — Rust helper for ServiceRadar native agent add-ons

`addon-sdk` lets a **Rust** add-on be launched and supervised by the
ServiceRadar agent's **existing, unmodified** HashiCorp `go-plugin` client. It
implements the plugin (server) half of the go-plugin wire protocol in Rust:
the stdout handshake line, AutoMTLS certificate exchange, and the
`proto/agent/addon/v1` gRPC `AddonService` served over a Unix-domain socket.

This is the Rust counterpart of the Go SDK (`go/pkg/addon`,
`go/pkg/addon/sdk`). The agent treats Go and Rust add-ons identically.

## Native metrics

Rust native add-ons that produce ServiceRadar metrics should emit them through
`AddonService.StreamTelemetry` with `addon_sdk::serviceradar_metric_record`.
The helper wraps one encoded `serviceradar.metric.v1.MetricBatch` in a
`TelemetryRecord` with payload kind `SERVICERADAR_METRICS`. The agent and
gateway preserve that payload and publish it to JetStream `metrics.*`; add-ons
must not smuggle metrics through JSON plugin results or source-specific JSON
arrays.

## Quick start

```rust
use addon_sdk::{serve, Addon, ConfigureResult, Health, HealthStatus, Info};
use async_trait::async_trait;

#[derive(Default)]
struct MyAddon;

#[async_trait]
impl Addon for MyAddon {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info { id: "my-addon".into(), version: "0.1.0".into(),
                  capabilities: vec!["my-cap".into()] })
    }
    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        // config_json is already validated by the control plane against
        // config.schema.json. Apply it and return a stable hash.
        Ok(ConfigureResult { config_hash: "...".into(), accepted: true, error: String::new() })
    }
    async fn health(&self) -> anyhow::Result<Health> {
        Ok(Health::default()) // healthy
    }
}

#[tokio::main]
async fn main() {
    if let Err(e) = serve(MyAddon).await { eprintln!("{e}"); std::process::exit(1); }
}
```

See `src/bin/rust_sample_addon.rs` for the full reference add-on.

## The go-plugin contract (pinned to go-plugin v1.8.0)

The agent (host) is the go-plugin client; the add-on (this crate) is the
server. The contract is intentionally language-neutral.

### Handshake

1. The host sets the magic-cookie env var before launching the plugin:
   `SERVICERADAR_ADDON_PLUGIN=serviceradar-addon-v1`. The plugin refuses to run
   as a plugin unless it matches (UX guard, not a security boundary).
2. The plugin binds a Unix-domain socket inside the host-restricted directory
   (`PLUGIN_UNIX_SOCKET_DIR`); group/permissions follow
   `PLUGIN_UNIX_SOCKET_GROUP`.
3. The plugin prints **exactly one** line to stdout and flushes:

   ```
   CORE|APP|unix|<socket-path>|grpc|<base64-der-server-cert>
   ```

   - `CORE` = go-plugin core protocol version (`1`).
   - `APP`  = application protocol version (`1`); must match
     `addon.ProtocolVersion` (Go) and the manifest's `plugin.app_protocol_version`.
   - `<base64-der-server-cert>` is the server leaf certificate DER in base64
     (standard alphabet, **no padding** — go-plugin's `base64.RawStdEncoding`),
     empty when AutoMTLS is off.
   - A 7th `|true` field is appended only when `PLUGIN_MULTIPLEX_GRPC` is set
     (gRPC broker multiplexing), matching go-plugin's old-client-safe behavior.

### gRPC services the plugin serves

- `serviceradar.agent.addon.v1.AddonService` (Info / Configure / Health).
- `grpc.health.v1.Health` reporting `SERVING` for the service named **`plugin`**
  (go-plugin's `GRPCServiceName`); the host pings this before dispensing.

### AutoMTLS

When the host launches with `AutoMTLS = true` it:

- generates a self-signed certificate, passes its **PEM** to the plugin in the
  `PLUGIN_CLIENT_CERT` env var, and uses that cert as its client identity;
- pins the plugin's returned cert (from the handshake line) as its **only**
  `RootCAs`/`ClientCAs` and dials with `ServerName = "localhost"`.

The plugin (this crate) responds by:

- generating its own self-signed `localhost` certificate, requiring + verifying
  the host's client cert against the host cert, and advertising its leaf cert
  DER (base64) in the handshake line.

#### Certificate shape and the Go↔Rust interop notes

Getting byte-compatible AutoMTLS against the unmodified Go go-plugin client
required three details that are easy to get wrong:

1. **The server cert must be a self-signed CA** (`IsCA: true`), exactly like
   go-plugin's `generateCert`. The Go client pins this single cert as its sole
   `RootCAs` and presents it as the leaf; Go's `crypto/x509` only accepts a
   pinned self-signed cert as a trust anchor when it carries CA basic
   constraints (a non-CA leaf yields *"x509: certificate signed by unknown
   authority"*).

2. **The cert must be serialized exactly once.** `rcgen` re-signs the
   TBSCertificate on every `serialize_*` call, and ECDSA signatures are
   randomized — so `serialize_der()` and `serialize_pem()` produce certs with
   identical bodies but *different signature bytes*. The host pins the DER we
   advertise in the handshake line and byte-compares the cert presented during
   the TLS handshake; serving a different serialization fails verification. We
   serialize the DER once and derive both the advertised value and the served
   identity from those same bytes.

3. **The crypto provider must support ECDSA P-521.** go-plugin's client cert is
   ECDSA P-521. rustls' default **ring** provider verifies only P-256/P-384
   signatures, so client-cert verification fails with *"tls: certificate
   required"*. This crate therefore uses the **aws-lc-rs** provider, which
   supports P-521. (aws-lc-rs builds a small C library; `cmake` + a C compiler
   are required at build time.)

Because go-plugin's certs are self-signed CAs, rustls' default WebPKI verifiers
reject them on both directions (a CA cert used as an end-entity →
`CaUsedAsEndEntity`). The crate therefore installs custom rustls verifiers that
**pin the peer cert by exact DER** — the byte-equivalent of Go's pin — for both
the server cert (client side) and the client cert (server side), with the
handshake signature still verified by the crypto provider so the peer must
actually hold the pinned cert's private key.

The authoritative proof that the agent's unmodified Go client accepts this Rust
server is `go/pkg/agent/addon/manager_rust_addon_test.go`, which launches the
Rust reference add-on through the real `Manager`/go-plugin client and drives
Info / Configure / Health over the supervised mTLS connection.

## Testing

```sh
# Rust-side handshake + mTLS sanity check (host role played within Rust):
cargo test -p addon-sdk

# Cross-language proof against the REAL Go go-plugin client:
cargo build -p addon-sdk --bin serviceradar-rust-sample-addon
SERVICERADAR_RUST_ADDON_BIN=$PWD/target/debug/serviceradar-rust-sample-addon \
  go test ./go/pkg/agent/addon/ -run RustAddon -v
```
