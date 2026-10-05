# serviceradar-bmp-collector

The Rust adapter backs the Bazel BMP collector image used by Helm and Docker
Compose. It accepts BMP v3 and publishes route events to NATS JetStream before
EventWriter persists them.

The default admission limits are 16 simultaneous sessions, an effective
256 KiB frame ceiling, and a 30-second absolute read deadline per frame.
The hard decoder ceiling bounds control-message TLV and statistics collections;
`max_frame_size_bytes` can lower this ceiling. Silent sessions allocate only
a stack header. A validated frame allocates its declared size once; additional
bytes stay in the socket until the next frame. The deadline includes both header
and body and cannot be renewed by trickling bytes. Listener accept errors retry
with a bounded backoff. `read_buffer_bytes` is retained for configuration
compatibility and no longer controls a per-session allocation.

A route-monitoring message may contain at most 8,192 combined announced,
withdrawn, and multiprotocol prefixes, including repeated MP attributes and
Add-Path inputs. The collector rejects the whole message before materializing
per-prefix updates. Prefix parsing itself still occurs in the bounded BGP
message decoder. Valid IPv4/IPv6 announcements and withdrawals retain their
existing JSON and subject contracts.

All publisher clones share limits of 1,000 messages and 4 MiB of serialized
payload per one-second window. Retries consume the same limits. Bursts wait
for shared capacity instead of partially publishing and closing the router session. A single serialized update larger than the byte allowance
is rejected. Defaults are configurable with `publish_messages_per_second` and
`publish_bytes_per_second`. These controls bound resource use, and do not
authenticate a BMP peer: restrict TCP ingress to trusted routers.

`stream_discard_policy` defaults to `"new"` on creation and reconciliation.
A full stream rejects incoming telemetry instead of evicting older sources'
records. New legitimate events also fail while full, until retention expiry
or operator removal frees capacity. Limits-retained records remain after consumer
acknowledgement; a healthy consumer alone cannot drain this storage.
An explicit `"old"` override restores rolling retention and accepts the risk of flood-driven eviction. Reconciliation retains
other metadata and existing subjects. Review stored usage before lowering the
byte cap, which can affect existing data independently of ingress policy.

Set `max_connections`, `max_frame_size_bytes`, and `read_timeout_secs` for the
available memory and router workload. Default frame storage is bounded by
16 * 256 KiB = 4 MiB, leaving headroom under the chart's 512 MiB limit for
prefix decoding, published updates, NATS, and runtime overhead. Increasing
`max_connections` requires accounting for the additional decoded collections
and runtime overhead in the memory limit. Configuring frames above 256 KiB
does not raise the hard decoder ceiling.

Prometheus counters are served at `/metrics` on `metrics_addr` (default
`0.0.0.0:9092`): `bmp_collector_rejected_sessions_total`,
`bmp_collector_accept_errors_total`, `bmp_collector_read_timeouts_total`,
`bmp_collector_rejected_frames_total`, `bmp_collector_rejected_prefixes_total`,
`bmp_collector_rejected_publishes_total`, and
`bmp_collector_throttled_publishes_total`. Alert on sustained counter
increases and JetStream storage nearing its configured cap.
