# Flowgger with NATS JetStream
This is a fork of [awslabs/flowgger](https://github.com/awslabs/flowgger) with NATS JetStream support, integrated into ServiceRadar’s monorepo. See our PR at [awslabs/flowgger#85](https://github.com/awslabs/flowgger/pull/85).

## Usage
Build: `cargo build --features "nats-output,grpc-health" --release`
Run: `./target/release/flowgger flowgger.toml`

### gRPC Health Checks

If the `[grpc]` section is configured in `flowgger.toml`, Flowgger starts a gRPC
health check server. TLS is enabled when `cert_file`, `key_file`, and `ca_file`
are all provided.

## Support
This fork is maintained for ServiceRadar. We welcome contributions aligned with this use case but cannot support other applications.
