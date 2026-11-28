# Change: Run UDP syslog, TCP syslog, and OTLP in one log collector

## Why

The `demo` namespace on the `carverauto` cluster runs two Deployments of
`serviceradar-log-collector`, three replicas each:

- `serviceradar-log-collector` listens for syslog on UDP 514 and for OTLP, and
  serves gRPC health on 50044. Its ClusterIP publishes UDP 514, TCP 4317, and
  TCP 50044. The external Service publishes UDP 514 only.
- `serviceradar-log-collector-tcp` runs the same image with OTEL turned off and
  listens for syslog on TCP 514. Its ClusterIP publishes TCP 514 and TCP 50044.
  No Gateway route and no external Service front it.

The chart does this because one Flowgger config has a single `[input]`
(`udp` or `tcp`), and `serviceradar-log-collector` starts one Flowgger pipeline.
Both processes also bind health on `0.0.0.0:50044`, so they cannot share a pod.
`values.yaml`, `values-demo.yaml`, `values-ha.yaml`, and `values-tenant.yaml`
all set `logCollector.tcpCollector.enabled: true`.

Both publish to the `events` stream on `logs.syslog`. The TCP Deployment is a
second copy of the collector, with its own pods, ConfigMap, Service, and
events-stream settings (`streamReplicas`, resources, replica count).

## What Changes

- Teach Flowgger to run additional listeners from `[[inputs]]` on the same
  output, so one process binds UDP syslog and TCP syslog and opens one NATS
  publisher.
- Render that TCP listener in the existing log-collector ConfigMap. Keep OTLP
  on the same process.
- Delete the `serviceradar-log-collector-tcp` Deployment and ConfigMap.
  **BREAKING** for anything that selected `app: serviceradar-log-collector-tcp`
  or depended on `logCollector.tcpCollector.replicaCount`, `.resources`, or
  `.streamReplicas` creating a second workload.
- Publish TCP 514 on `serviceradar-log-collector`. Keep a Service named
  `serviceradar-log-collector-tcp` with no pods of its own, selecting only pods
  that listen for TCP syslog, so the DNS name demo already uses survives the
  upgrade.
- Fold an enabled TCP external Service into `serviceradar-log-collector-external`.
  Remove `serviceradar-log-collector-tcp-external`.
- Honor `logCollector.tcpCollector.enabled`, `.listen`, `.format`, and
  `.framing` as the TCP listener on the unified collector. Fail the render when
  `.subject` is set to anything other than `logs.syslog`.
- Describe one collector in the syslog docs, the port map, the chart README,
  and the Compose stack.

## Impact

### Performance research extension

The accompanying [performance investigation](performance.md) evaluates the
collector and processor path for high-volume fleets of 100,000 or more hosts.
The preferred experiment is collector-side Zen, with versioned rule snapshots
delivered through serviceradar-datasvc/NATS KV, followed by bounded protobuf
batches and pipelined JetStream publishes. It also evaluates copy avoidance,
recvmmsg/Compio, adapted Broadway consumers, standalone Rust consumers, and
storage encoding and partitioning.

This adds research and benchmark tasks, not an immediate wire-format change or
consumer replacement. Listener consolidation remains independently shippable.
Zen and existing log semantics must be preserved. A binary cutover, partitioned
streams, or replacement EventWriter requires reviewed requirements of its own;
the current fixed subject/stream and persistence contracts below remain intact.

### Consolidation impact

- Affected specs: `log-collector` (new). `observability-signals` is unchanged;
  syslog still lands on `logs.syslog` / `events` and is still stored as a log.
- Affected code:
  - `rust/flowgger` (multi-listener start, shared output)
  - `rust/log-collector` (one Flowgger pipeline covers every configured listener)
  - `helm/serviceradar/templates/log-collector.yaml`
  - `helm/serviceradar/templates/log-collector-tcp.yaml` (remove)
  - `helm/serviceradar/templates/network-policy.yaml`
  - `helm/serviceradar/values.yaml`, `values-demo.yaml`, `values-ha.yaml`,
    `values-tenant.yaml`
  - Helm tests that render `templates/log-collector-tcp.yaml`
  - `docker-compose.yml` and `docker/compose/flowgger.docker.toml`
  - `docs/docs/syslog.md`, `docs/docs/service-ports.md`,
    `docs/docs/service-port-map.md`, `helm/serviceradar/README.md`
- Pending changes that still name the TCP Deployment:
  `update-demo-control-plane-ha`, `harden-pod-dns-and-cluster-resolver`, and
  `update-documentation-accuracy-and-coverage`. Update those deltas in this
  change so a later archive does not put the second Deployment back into a spec.
- The log-collector certificate already carries
  `DNS:serviceradar-log-collector-tcp.<namespace>.svc.cluster.local`. This
  change keeps that name. It does not bump `certs.runtimeLayoutVersion`.
