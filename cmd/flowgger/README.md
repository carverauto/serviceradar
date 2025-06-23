# Flowgger with NATS JetStream
This is a fork of [awslabs/flowgger](https://github.com/awslabs/flowgger) with NATS JetStream support, integrated into ServiceRadar’s monorepo. See our PR at [awslabs/flowgger#85](https://github.com/awslabs/flowgger/pull/85).

## Usage
Build: `cargo build --features nats-output --release`
Run: `./target/release/flowgger flowgger.toml`

## Support
This fork is maintained for ServiceRadar. We welcome contributions aligned with this use case but cannot support other applications.

## gRPC Health Checks

Flowgger can expose a gRPC health endpoint compatible with ServiceRadar's monitoring
protocol. Enable it by adding a `grpc` section to `flowgger.toml`:

```toml
[grpc]
listen_addr = "0.0.0.0:50057"
tls_ca_file = "/etc/serviceradar/certs/root.pem"
tls_cert = "/etc/serviceradar/certs/core.pem"
tls_key = "/etc/serviceradar/certs/core-key.pem"
```

These certificates are separate from the NATS credentials used for JetStream.
