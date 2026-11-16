## 1. Flowgger listeners

- [x] 1.1 Teach `start_pipeline` to run each `[[inputs]]` entry on its own thread, with its own decoder and encoder, publishing into the one `[output]` channel.
- [x] 1.2 Keep a config that has only `[input]` on the current single-listener path.
- [x] 1.3 Fail startup on an unknown extra-listener type and on two listeners with the same type and listen address.
- [x] 1.4 Apply `[input].rfc3164_timezone` to every listener.
- [x] 1.5 Add a Flowgger test that a UDP listener and a TCP listener in one config share one output and publish both payloads.

## 2. Log collector

- [x] 2.1 Keep `serviceradar-log-collector` starting one Flowgger pipeline and one OTEL collector. The TCP listener is inside the Flowgger config, not a second pipeline and not a process with `[otel] enabled = false`.
- [x] 2.2 Confirm a failed listener bind still exits the process so the gRPC readiness probe fails.

## 3. Helm chart

- [x] 3.1 Render the TCP `[[inputs]]` entry in `serviceradar-log-collector-config` from `logCollector.tcpCollector.enabled`, `.listen`, `.format`, and `.framing`.
- [x] 3.2 Add container port `syslog-tcp` (TCP 514) and the pod label `serviceradar.io/syslog-tcp: "true"` when TCP is enabled.
- [x] 3.3 Add Service port `syslog-tcp` on `serviceradar-log-collector` when TCP is enabled.
- [x] 3.4 Replace the TCP Deployment, ConfigMap, and external Service with a compatibility Service `serviceradar-log-collector-tcp` that selects the labeled pods and exposes only TCP 514.
- [x] 3.5 Ignore `logCollector.tcpCollector.replicaCount`, `.resources`, and `.streamReplicas`. Fail the render when `.subject` is set and is not `logs.syslog`.
- [x] 3.6 Add `logCollector.externalService.ports.syslogTcp`. Honor `logCollector.tcpCollector.externalService.enabled` by enabling that port. Fail the render when the two external Services set different `loadBalancerIP` values. Point the TCP external NetworkPolicy at `app: serviceradar-log-collector` and drop the policy that selected `app: serviceradar-log-collector-tcp`.
- [x] 3.7 Leave the log-collector certificate SAN for `serviceradar-log-collector-tcp.<namespace>.svc.cluster.local` in place. Do not bump `certs.runtimeLayoutVersion`.
- [x] 3.8 Update `values.yaml`, `values-demo.yaml`, `values-ha.yaml`, and `values-tenant.yaml` comments so replica and stream settings are not described as a second Deployment. Preserve overlays that explicitly disable external TCP.
- [x] 3.9 Retarget Helm tests that render `templates/log-collector-tcp.yaml` (`syslog_format_test.yaml`, `jetstream_replicas_cap_test.yaml`, `jetstream_sizes_env_test.yaml`) at the unified collector, including a case where `tcpCollector.enabled` is false and a case where a foreign `tcpCollector.subject` fails the render.

## 4. Compose and docs

- [x] 4.1 Add the TCP `[[inputs]]` entry to `docker/compose/flowgger.docker.toml` and publish `514:514/tcp` on the existing Compose `log-collector` service.
- [x] 4.2 Update `docs/docs/syslog.md`, `docs/docs/service-ports.md`, `docs/docs/service-port-map.md`, and `helm/serviceradar/README.md` so TCP syslog is a listener on `serviceradar-log-collector`. Name `serviceradar-log-collector-tcp` only as the compatibility Service.

## 5. Pending OpenSpec deltas

- [x] 5.1 In `update-demo-control-plane-ha`, stop naming a `log-collector-tcp` Deployment as its own replicated ingest service. The unified log collector remains the replicated syslog deployment.
- [x] 5.2 In `harden-pod-dns-and-cluster-resolver`, drop `log-collector-tcp.yaml` from the deployment list. Keep the compatibility Service's DNS SAN.
- [x] 5.3 In `update-documentation-accuracy-and-coverage`, describe TCP syslog on the unified collector instead of documenting `templates/log-collector-tcp.yaml` as a second collector.

## 6. Verification

- [x] 6.1 `openspec validate consolidate-log-collectors --strict` passes.
- [x] 6.2 Flowgger tests cover the shared-output case and the unchanged single-input case.
- [x] 6.3 `helm unittest` covers the unified Service ports, the label-selected compatibility Service, TCP disabled, and the foreign-subject failure.
- [ ] 6.4 After a deployment upgrade, `serviceradar-log-collector-tcp` has no Deployment, its endpoints are only pods labeled `serviceradar.io/syslog-tcp=true`, and one TCP message and one UDP message both arrive on `logs.syslog`.

## 7. Companion proposal ownership

Performance implementation and benchmark tasks are owned by
`accelerate-log-ingestion`, `partition-log-ingestion` and
`add-zero-copy-log-receivers`. This consolidation does not claim those
capabilities are implemented by enabling simultaneous listeners.
