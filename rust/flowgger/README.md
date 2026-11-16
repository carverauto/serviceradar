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
A TCP listener logs a failed `accept` or a failed connection-handler thread
start to stderr and retries after 100 ms; it ends only when the listening socket
itself is unusable.

## JetStream publish window

The NATS output pipelines acknowledgments on each worker's connection. Configure
`output.nats_max_inflight` (default `32`) and
`output.nats_max_inflight_bytes` (default `8388608`, or 8 MiB) to bound pending
messages and their encoded payload bytes. Set the count to `1` for serial
publishing. Both values must be positive integers. A record larger than the byte
budget fails the output explicitly rather than waiting forever or being dropped.

These limits apply **per `nats_threads` worker**, including records waiting for
retry. Each worker still owns a connection and stream reconciliation. A retry
retains its original message ID, payload and admission slot; reconnects within a
worker are coordinated. Concurrent publishing does not guarantee completion order.
Closing the input queue drains pending publishes before flushing. An ambiguous
ACK failure is retried only within the stream's duplicate window; send failures
before possible persistence retain the configured connection retry policy.

A fatal output error still stops the collector. Records already admitted get one
`output.nats_timeout` to be acknowledged first; the error then reports how many
were abandoned. Records still in the input queue are not published.

To compare windows on a workstation, run the synthetic benchmark once per
window. It needs `nats-server` on `PATH` or in `NATS_SERVER_BIN`, and reports
the time until the broker has stored every record:

```text
cargo run --release --features nats-output --example publish_window_bench -- \
    --window 1 --records 200000 --bytes 256
```

The limits cover pending encoded payloads, not total process memory. Each worker
also has a one-entry async queue, at most one record held by its blocking bridge,
and at most one encoded record staged for byte admission. The upstream Flowgger
record queue and client/TLS buffers have their own memory costs. One persistent
bridge thread per worker keeps an idle synchronous queue off the Tokio runtime.

## Support
This fork is maintained for ServiceRadar. We welcome contributions aligned with this use case but cannot support other applications.
