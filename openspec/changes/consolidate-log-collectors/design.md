## Context

Flowgger previously starts one input and one output. The chart uses another
collector workload for TCP syslog. Consolidation runs independent listeners in
one process, retaining the existing OTLP collector and gRPC health service.

## Goals and scope

One Deployment and process accept configured UDP/TCP/OTLP traffic. Listeners
share one logical output and its configured publisher workers. Keep the old
TCP Service address, single-input configs, current wire format, existing
certificate SANs and optional TCP enablement.

TLS syslog expansion, binary transport, Zen relocation, sharding and accelerated
receive have their own companion proposals. Do not change packaged edge-unit
listeners automatically.

## Listener lifecycle

Additional listeners are `[[inputs]]` alongside `[input]`. Each owns its
decoder/framing and input settings; `[input].rfc3164_timezone` is shared.
Validate configuration before starting output. Reject unknown types and
duplicate sockets, including aliases for the same TCP transport.

Start independent blocking input loops and supervise their completion. A
listener panic or unexpected return must propagate to the process owner; a
detached failed listener must not leave a healthy-looking partial collector.
Single-input execution retains its existing behavior.

Initialize the logical output once. Default `nats_threads = 1` gives one
publisher worker; explicitly configured extra workers retain their established
connections/reconciliation. Adding listeners must not multiply that count.

## Chart and Service contracts

`logCollector.tcpCollector.enabled/listen/format/framing` configure the extra
listener. Replica/resource/stream-replica keys no longer create another
workload. The unified workload uses `logCollector.replicaCount/resources`.
Reject a TCP output subject different from `logs.syslog`.

The primary Service exposes TCP when configured, using named target
`syslog-tcp`. The old TCP Service selects unified pods with
`serviceradar.io/syslog-tcp: "true"` and retains its DNS name. Keep its existing
Service metadata/port customization where meaningful; it has no health port
or independent workload. Old pods without TCP capability must not be alias
endpoints. Verify named-port behavior in rollout tests rather than assuming
all primary Service endpoints can receive every protocol.

For a custom TCP listen port, the operator also sets
`tcpCollector.service.ports.syslog.targetPort` to that numeric port. Use this
value consistently for the declared TCP container port and Service routing;
do not attempt to infer every supported listen-address syntax in Helm.

External UDP and TCP use one external Service. Each port is independently
controlled. An enabled legacy TCP external block remains a migration input.
When only that block enables exposure, preserve its Service type, annotations,
traffic policy and port mapping. When the primary external block is enabled,
its Service metadata wins. Active legacy TCP port settings remain applicable;
document this precedence. Conflicting pinned addresses fail clearly.

NetworkPolicy uses the same resolved port definition as the external Service
and allows the container destination port, which may differ from the external
port. Do not recreate a policy selecting the removed TCP workload.
An overlay explicitly disabling external TCP remains UDP-only.

Compose adds `514/tcp` on the existing collector and the same additional-input
config. Docs identify the former TCP name only as a compatibility Service.

## Rollout and rollback

1. Ship a binary supporting additional listeners, preserving old single-input
   configuration.
2. Roll the chart/image together. New pods gain the listener and selector label;
   the old TCP Service becomes an alias and the redundant workload disappears.
3. Verify both UDP and TCP reach the expected subject, alias endpoints have the
   TCP label, and OTLP/health remain operational.
4. Roll image and chart back together if needed; the previous chart restores
   its separate TCP workload. Do not silently remove retained log data.

A bind failure ends the process and fails readiness. The alias can have no
endpoints while new pods become Ready; this is preferable to selecting pods
without a TCP listener. Combined load may require a new resource budget; do
not simply add previous replica counts.

## Companion work

[performance.md](performance.md) contains the source-backed investigation.
[zero-copy.md](zero-copy.md) explains memory ownership and kernel boundaries.
The approved companion proposals own normalization/binary transport,
partitioned JetStream topology and optional accelerated receive.
[implementation.md](implementation.md) records current pass status.
