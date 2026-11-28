## Context

`serviceradar-log-collector` (`rust/log-collector`) starts one Flowgger pipeline
from `[flowgger].config_file` and, when enabled, the OTEL collector from
`[otel].config_file`. Health is one gRPC server on `[health].listen_addr`
(chart default `0.0.0.0:50044`).

Flowgger's `start_pipeline` reads one `input.type` and one `output`, then blocks
in `Input::accept`. The Helm TCP template is the same binary with a second
ConfigMap: `[otel] enabled = false`, `[input] type = "tcp"`, `framing = "line"`,
and the same NATS `events` / `logs.syslog` output. That second process exists
so UDP 514 and TCP 514 can both be bound, and so two health servers on 50044
do not collide.

On `demo` the useful split is the listen protocol. The image, the NATS subject,
the certificate, and the downstream core path are already the same. OTLP stays
on the UDP Deployment (`serviceradar-otlp` selects `app: serviceradar-log-collector`).
TCP syslog is in-cluster only: `serviceradar-log-collector-tcp` is a ClusterIP,
and the namespace has no syslog TCPRoute.

## Goals / Non-Goals

- Goals:
  - One Deployment and one process accept UDP syslog, TCP syslog, and OTLP.
  - Both syslog transports share one NATS publisher and one events-stream
    reconcile.
  - The DNS name `serviceradar-log-collector-tcp` keeps delivering TCP syslog
    to pods that are actually listening.
  - `logCollector.tcpCollector.enabled: false` still means "do not bind TCP".
  - Compose exposes both transports on the existing `log-collector` service.
- Non-Goals:
  - A TLS syslog listener. Flowgger can do `tls`, and this change does not add
    a third listen mode.
  - A new NATS subject, Zen rule, or storage path.
  - Adding the replica counts of the two Deployments. The unified Deployment
    uses `logCollector.replicaCount` and `logCollector.resources`.
  - Deleting the compatibility Service name.
  - Per-listener gRPC health names. The process still reports `log-collector`,
    `flowgger`, and `otel`.
  - Turning TCP syslog on in the packaged edge unit. That unit stays a single
    `[input]` of type `udp` until an operator adds `[[inputs]]`.
  - A cert-layout bump. The TCP Service SAN stays.

## Decisions

- Decision: additional listeners are `[[inputs]]` entries beside the existing
  `[input]` table, and they share `[output]`.

  A current UDP config keeps working with no `[[inputs]]` key. The chart, when
  TCP is enabled, renders the UDP listener as `[input]` and the TCP listener
  as one `[[inputs]]` entry (`type`, `listen`, `format`, `framing`).
  `rfc3164_timezone` stays on `[input]` and applies to every listener. Each
  extra listener builds its own decoder and encoder from its format and
  framing, then sends into the channel the single output already drains.
  `start_pipeline` spawns one thread per extra listener because `accept`
  blocks. One NATS output means one events-stream reconcile per process.

  A config that only has `[input]` is the packaged and standalone Flowgger
  shape. Duplicate `type` + `listen` pairs, and an unknown `type`, fail
  startup the way an unknown `input.type` fails today.

- Decision: do not start a second Flowgger pipeline from a second file.

  Two `start_pipeline` calls would open two NATS outputs and reconcile
  `events` twice in one pod. That repeats the split this change is removing.
  Two containers in one pod collide on 50044 and still look like two collectors.

- Decision: `logCollector.tcpCollector` remains the Helm switch for the TCP
  listener.

  `enabled`, `listen` (default `0.0.0.0:514`), `format` (default `auto`), and
  `framing` (default `line`) render the `[[inputs]]` entry.
  `replicaCount`, `resources`, and `streamReplicas` are ignored. The events
  reservation is the one `serviceradar.jetstreamBudget` already gives the log
  collector. A `subject` other than `logs.syslog` fails `helm template`,
  because one output cannot publish the same records to two subjects and no
  overlay sets another subject today.

- Decision: one Service can carry UDP 514 and TCP 514, and the old TCP name
  becomes a selector alias.

  `serviceradar-log-collector` gains port `syslog-tcp` (TCP 514) when TCP is
  enabled. Its selector stays `app: serviceradar-log-collector`, so UDP and
  OTLP keep reaching pods from the previous image during the rollout.

  `serviceradar-log-collector-tcp` stays a Service and loses its Deployment.
  It selects `app: serviceradar-log-collector` plus a new pod label
  `serviceradar.io/syslog-tcp: "true"`, which the pod template sets only when
  TCP is enabled. It exposes TCP 514 and does not expose 50044. Pods from the
  previous image lack the label, so the name demo uses for TCP syslog does not
  land on a pod that only binds UDP.

  Kubernetes has one selector per Service. The primary Service's new TCP port
  will include old pods until the rollout finishes. Existing TCP senders use
  the alias, which excludes those pods. Senders that adopt the primary Service
  name during that window can hit a pod that refuses TCP 514.

- Decision: external TCP joins the existing external Service.

  `logCollector.externalService.ports.syslogTcp` is the TCP port block
  (default enabled when TCP syslog is enabled, port 514, protocol TCP).
  `logCollector.tcpCollector.externalService.enabled: true` turns that port on
  even when the operator has not set the new key. The external Service is
  rendered when either the UDP port or the TCP port is enabled. Different
  `loadBalancerIP` values on the old TCP external Service and the log-collector
  external Service fail the render. The network policy that allowed the TCP
  external CIDRs selects `app: serviceradar-log-collector` and is not a
  separate policy named for the TCP Deployment. Demo leaves TCP external off;
  its UDP external Service stays UDP-only unless `syslogTcp` is enabled.

- Decision: Compose binds `514/tcp` on the same `log-collector` service and
  adds the same `[[inputs]]` entry to `docker/compose/flowgger.docker.toml`.

## Risks / Trade-offs

- A TCP bind failure aborts the process, so UDP syslog and OTLP stop with it.
  TCP is optional: leave the listener out of the config and the other inputs
  start. Mitigation: bind failure must exit before the pod is Ready, which
  Flowgger already does by panicking out of `accept` on a failed bind. The
  gRPC health server still starts in parallel; process exit is what fails the
  probe. This change does not add a new health protocol.

- Demo's six collector pods become three. Each unified pod does the work both
  Deployments do today, at `logCollector.resources` (the demo overlay's
  request and limit, not the sum of the two Deployments). Syslog lag after the
  cut is the signal to raise that budget. Do not set `replicaCount` to 6 to
  recreate the old footprint.

- The alias Service has no endpoints from the selector change until the first
  new pod is Ready. TCP syslog to `serviceradar-log-collector-tcp` fails closed
  for that interval instead of being delivered to a UDP-only pod.

- Pending OpenSpec deltas still mention a `log-collector-tcp` Deployment.
  Archive of `update-demo-control-plane-ha` would record that Deployment as a
  replicated ingest service. Update the pending wording in this change.

## Migration Plan

1. Ship the binary that accepts `[[inputs]]` and still accepts a single
   `[input]`.
2. Upgrade the release. The chart adds the TCP listener and the pod label,
   retargets `serviceradar-log-collector-tcp` at labeled pods, adds TCP 514 to
   `serviceradar-log-collector`, and deletes the TCP Deployment, its ConfigMap,
   and `serviceradar-log-collector-tcp-external`.
3. After the unified rollout, confirm the alias Service's endpoints are only
   the new pods and that a TCP 514 message and a UDP 514 message both arrive
   on `logs.syslog`.
4. Rollback is the previous chart: it recreates the TCP Deployment and points
   the TCP Service back at `app: serviceradar-log-collector-tcp`. The new
   `[[inputs]]` key is ignored by the previous binary only if that binary is
   what the rolled-back Deployment runs. Roll the image and the chart back
   together.

## Open Questions

- None that block the change. Removing the compatibility Service is a later
  change, after senders use `serviceradar-log-collector` TCP 514.

## Performance research track

See [performance.md](performance.md) for source-backed findings, the capacity
model, and benchmark gates. Product-owner preference is to evaluate Zen inside
Flowgger before publishing normalized protobuf, with cached rules delivered
through datasvc from NATS KV. Preserve rule authoring, updates, provenance,
redaction, promotion and replay behavior; do not obtain a performance gain by
silently skipping them.

The immediate candidates are bounded concurrent JetStream publishes, eliminating
duplicate serialization, batching and buffer reuse. Compare recvmmsg and Compio
only after isolating receiver costs. Compare adapted Broadway and standalone
Rust consumers on the same normalized data and persistence contract. Current
StarRocks Stream Load still needs a supported storage encoding; protobuf on
NATS is not direct protobuf ingestion into StarRocks.

The evaluation must resolve rule snapshot activation and failure policy,
ingest-time versus replay-time normalization, binary schema and migration,
per-source ordering, durability before JetStream ACK, workload/latency targets,
and stream partitioning before those extensions become implementation tasks.
These questions do not block the existing multi-listener consolidation.
