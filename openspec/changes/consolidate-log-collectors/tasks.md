## 1. Flowgger listeners

- [ ] 1.1 Teach `start_pipeline` to run each `[[inputs]]` entry on its own thread, with its own decoder and encoder, publishing into the one `[output]` channel.
- [ ] 1.2 Keep a config that has only `[input]` on the current single-listener path.
- [ ] 1.3 Fail startup on an unknown extra-listener type and on two listeners with the same type and listen address.
- [ ] 1.4 Apply `[input].rfc3164_timezone` to every listener.
- [ ] 1.5 Add a Flowgger test that a UDP listener and a TCP listener in one config share one output and publish both payloads.

## 2. Log collector

- [ ] 2.1 Keep `serviceradar-log-collector` starting one Flowgger pipeline and one OTEL collector. The TCP listener is inside the Flowgger config, not a second pipeline and not a process with `[otel] enabled = false`.
- [ ] 2.2 Confirm a failed listener bind still exits the process so the gRPC readiness probe fails.

## 3. Helm chart

- [ ] 3.1 Render the TCP `[[inputs]]` entry in `serviceradar-log-collector-config` from `logCollector.tcpCollector.enabled`, `.listen`, `.format`, and `.framing`.
- [ ] 3.2 Add container port `syslog-tcp` (TCP 514) and the pod label `serviceradar.io/syslog-tcp: "true"` when TCP is enabled.
- [ ] 3.3 Add Service port `syslog-tcp` on `serviceradar-log-collector` when TCP is enabled.
- [ ] 3.4 Replace the TCP Deployment, ConfigMap, and external Service with a compatibility Service `serviceradar-log-collector-tcp` that selects the labeled pods and exposes only TCP 514.
- [ ] 3.5 Ignore `logCollector.tcpCollector.replicaCount`, `.resources`, and `.streamReplicas`. Fail the render when `.subject` is set and is not `logs.syslog`.
- [ ] 3.6 Add `logCollector.externalService.ports.syslogTcp`. Honor `logCollector.tcpCollector.externalService.enabled` by enabling that port. Fail the render when the two external Services set different `loadBalancerIP` values. Point the TCP external NetworkPolicy at `app: serviceradar-log-collector` and drop the policy that selected `app: serviceradar-log-collector-tcp`.
- [ ] 3.7 Leave the log-collector certificate SAN for `serviceradar-log-collector-tcp.<namespace>.svc.cluster.local` in place. Do not bump `certs.runtimeLayoutVersion`.
- [ ] 3.8 Update `values.yaml`, `values-demo.yaml`, `values-ha.yaml`, and `values-tenant.yaml` comments so replica and stream settings are not described as a second Deployment. Leave demo's TCP external Service off.
- [ ] 3.9 Retarget Helm tests that render `templates/log-collector-tcp.yaml` (`syslog_format_test.yaml`, `jetstream_replicas_cap_test.yaml`, `jetstream_sizes_env_test.yaml`) at the unified collector, including a case where `tcpCollector.enabled` is false and a case where a foreign `tcpCollector.subject` fails the render.

## 4. Compose and docs

- [ ] 4.1 Add the TCP `[[inputs]]` entry to `docker/compose/flowgger.docker.toml` and publish `514:514/tcp` on the existing Compose `log-collector` service.
- [ ] 4.2 Update `docs/docs/syslog.md`, `docs/docs/service-ports.md`, `docs/docs/service-port-map.md`, and `helm/serviceradar/README.md` so TCP syslog is a listener on `serviceradar-log-collector`. Name `serviceradar-log-collector-tcp` only as the compatibility Service.

## 5. Pending OpenSpec deltas

- [ ] 5.1 In `update-demo-control-plane-ha`, stop naming a `log-collector-tcp` Deployment as its own replicated ingest service. The unified log collector remains the replicated syslog deployment.
- [ ] 5.2 In `harden-pod-dns-and-cluster-resolver`, drop `log-collector-tcp.yaml` from the deployment list. Keep the compatibility Service's DNS SAN.
- [ ] 5.3 In `update-documentation-accuracy-and-coverage`, describe TCP syslog on the unified collector instead of documenting `templates/log-collector-tcp.yaml` as a second collector.

## 6. Verification

- [ ] 6.1 `openspec validate consolidate-log-collectors --strict` passes.
- [ ] 6.2 Flowgger tests cover the shared-output case and the unchanged single-input case.
- [ ] 6.3 `helm unittest` covers the unified Service ports, the label-selected compatibility Service, TCP disabled, and the foreign-subject failure.
- [ ] 6.4 After a demo upgrade, `serviceradar-log-collector-tcp` has no Deployment, its endpoints are only pods labeled `serviceradar.io/syslog-tcp=true`, and one TCP message and one UDP message both arrive on `logs.syslog`.

## 7. Performance research (independent of listener consolidation)

- [ ] 7.1 Agree on synthetic offered-load profiles, loss/durability requirements, p99 searchable latency and cost budgets using `performance.md`; establish a controlled Linux baseline through storage, not just receive rate.
- [ ] 7.2 Evaluate bounded publish concurrency, a persistent queue bridge, single encoding and byte/count/age-bounded batches while preserving ACK retry and certificate policy.
- [ ] 7.3 Design and benchmark collector-side Zen with a shared Rust normalization implementation and datasvc-delivered versioned rule snapshots; verify rule scope/order, updates, reconnects, deletion, cold start and semantic parity.
- [ ] 7.4 Specify an OTLP protobuf comparator and normalization metadata, complete JSON/protobuf field parity, and define mixed-version rollout and batch replay identity before changing the wire contract.
- [ ] 7.5 Measure borrowed parsing/buffer reuse, recvmmsg/SO_REUSEPORT, async TCP and Compio multishot against the same publisher and rules; label application copy avoidance separately from kernel zero-copy.
- [ ] 7.6 Profile normalized protobuf through Broadway; compare moving CPU work into bounded processors with standalone Rust EventWriter consumers, retaining persistence ownership, redaction, promotion, service/live-log effects and CNPG support.
- [ ] 7.7 Compare final StarRocks JSON and CSV batch encoding with identical rows and ACK semantics; require verified support before considering binary warehouse ingestion.
- [ ] 7.8 Evaluate independently partitioned streams, shared durable consumers and storage/query capacity at scale; record non-overlapping subject ownership, ordering, resharding and migration requirements in a follow-up proposal before implementation.
- [ ] 7.9 Prototype AF_XDP UDP and io_uring ZC Rx TCP per `zero-copy.md`; verify actual zero-copy operation, packet/framing semantics and buffer recycling, then compare receive and durable searchable throughput. Keep a supported conventional backend for Kubernetes workers and edge VMs, with explicit/automatic selection and observable fallback reasons.
- [ ] 7.10 Benchmark native Zen Variables with shared HipStr slices against the current JSON adapter; preserve null/overlay and aliasing semantics, inspect JS node costs, and evaluate a narrow upstreamable receive-lease string extension only after measuring the remaining ownership copy.
- [ ] 7.11 Validate the Kubernetes deployment contract: distinguish hypervisor/guest/pod networking, qualify dedicated device exposure, test actual io_uring calls under seccomp, and scope accelerated-mode capabilities to collectors. Keep live inventory and operational probe output outside committed artifacts; use synthetic workloads for reproducible tests.
