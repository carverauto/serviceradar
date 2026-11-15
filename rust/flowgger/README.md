# Flowgger with NATS JetStream
This is a fork of [awslabs/flowgger](https://github.com/awslabs/flowgger) with NATS JetStream support, integrated into ServiceRadar's monorepo. See our PR at [awslabs/flowgger#85](https://github.com/awslabs/flowgger/pull/85).

## Usage
Build: `cargo build --features nats-output --release`
Run: `./target/release/flowgger flowgger.toml`

### Multiple listeners

Keep the primary `[input]` and add `[[inputs]]` tables to accept additional
transports in the same pipeline:

```toml
[input]
type = "udp"
listen = "0.0.0.0:514"
format = "auto"
rfc3164_timezone = "UTC"

[[inputs]]
type = "tcp"
listen = "0.0.0.0:514"
format = "auto"
framing = "line"
```

All listeners feed the existing `[output]`; adding a listener does not create
another output or NATS worker group. Each listener has its own input settings
and codec instances. The primary `input.rfc3164_timezone` applies to every
listener, and `input.queuesize` controls their shared queue. A configuration
without `[[inputs]]` retains its single-input behavior.

Duplicate socket configurations and unknown input types fail startup. With
multiple listeners, a listener panic or exit fails the whole pipeline so an
embedding collector cannot continue reporting healthy after losing a listener.

## Support
This fork is maintained for ServiceRadar. We welcome contributions aligned with this use case but cannot support other applications.
