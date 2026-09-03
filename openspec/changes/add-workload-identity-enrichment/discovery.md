# Workload Identity Discovery Notes

## Existing Attribution Path

Current netprobe attribution is process-level and does not carry workload identity.

- `rust/netprobe/src/attribution.rs` emits `FlowAttributionEvent` from eBPF ring records with local/remote tuple, PID, TGID, UID, GID, comm, redacted cmdline, container ID, socket address, event kind, and TCP state fields.
- `proto/agent/netprobe/v1/netprobe.proto` carries those events in `FlowAttributionEvent` and `FlowAttributionEventBatch`; `ProcessSnapshotEntry` carries the same process/container fields for device process-listener views.
- `go/pkg/agent/push_loop_flow_attribution.go` batches those observations as retained `FlowAttributionEventBatch` payloads on the agent-owned `StreamStatus` path; the authenticated agent-gateway forwards that status to core.
- `elixir/serviceradar_core/lib/serviceradar/status_handler.ex` derives agent and partition authority from the authenticated status context, decodes the batch, and calls the public `ServiceRadar.FlowAttribution.persist/3` facade; that facade delegates row insertion to `ServiceRadar.FlowAttribution.Persistence`, which upserts bounded current state in `platform.flow_process_attribution_current`.
- `ServiceRadar.FlowAttribution.Correlation` joins that current state to independently ingested `platform.ocsf_network_activity` rows and stamps the matching existing `ocsf_payload` in place with `event_type=attributed_flow`, `agent_id`, and `attribution.{pid,comm,redacted_cmdline,uid,container_id}`.
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/flows/attributed_live.ex` reads workload-visible data only from `ocsf_payload.attribution` today, so namespace/pod/container name/image fields need either a proto/schema extension or a companion workload identity observation joined before render.
- Device process listeners render from device metadata `local_processes` and currently show endpoint, protocol, process, PID/TGID, UID/GID, container ID, and command only.

The earlier `HostSliceSubscriber` / `AttributedFlowJoiner` demo canary and its
`flow.host-slice.*` / `flow.attributed.*` subjects remain useful historical
evidence, but they are retired and are not current or future production routing.

## Kubernetes CRI Validation

Date: 2026-06-06.

All demo Kubernetes workers expose k3s containerd through `/run/k3s/containerd/containerd.sock` and have `crictl` at `/usr/local/bin/crictl`.

Validation commands:

```sh
CRI_ENDPOINT=unix:///run/k3s/containerd/containerd.sock

sudo crictl --runtime-endpoint "$CRI_ENDPOINT" pods
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" ps
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" inspectp <pod-sandbox-id>
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" inspect <container-id>
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" inspectp <pod-sandbox-id> | jq '.status.metadata, .status.labels, .status.linux.namespaces'
sudo crictl --runtime-endpoint "$CRI_ENDPOINT" inspect <container-id> | jq '.status.metadata, .status.image, .info.pid, .info.runtimeSpec.linux.cgroupsPath'
```

Observed node-local metadata:

| Node | Pods | Containers | Sample pod identity | Sample container identity |
| --- | ---: | ---: | --- | --- |
| k8s-cp2-worker1 | 82 | 81 | `demo/serviceradar-datasvc-7c6f79649-98s8v`, pod UID, labels, annotations, sandbox cgroup path | `datasvc`, image digest, runtime PID, labels, annotations, container cgroup path |
| k8s-cp2-worker2 | 98 | 95 | `renovate/renovate-29678777-z9sqr`, pod UID, labels, annotations, sandbox cgroup path | `renovate`, image ref, runtime PID, labels, annotations, container cgroup path |
| k8s-cp2-worker3 | 43 | 44 | `forgejo-actions/forgejo-runner-serviceradar-678f68685-xs65c`, pod UID, labels, annotations, sandbox cgroup path | `dind`, image ref, runtime PID, labels, annotations, container cgroup path |
| k8s-cp3-worker1 | 109 | 99 | `forgejo-actions/forgejo-runner-serviceradar-678f68685-gtvgk`, pod UID, labels, annotations, sandbox cgroup path | `dind`, image ref, runtime PID, labels, annotations, container cgroup path |
| k8s-cp3-worker2 | 33 | 42 | `forgejo-actions/forgejo-runner-serviceradar-678f68685-q5vsk`, pod UID, labels, annotations, sandbox cgroup path | `dind`, image ref, runtime PID, labels, annotations, container cgroup path |
| k8s-cp3-worker3 | 86 | 83 | `forgejo-actions/forgejo-runner-serviceradar-678f68685-mxxgp`, pod UID, labels, annotations, sandbox cgroup path | `dind`, image ref, runtime PID, labels, annotations, container cgroup path |

Conclusion: direct worker-node CRI access is enough for the MVP baseline: namespace, pod name, pod UID, container name, image, runtime PID, cgroup path, and selected runtime-exposed labels/annotations. Kubernetes API/RBAC is not required for this baseline. The optional overlay is still needed for owner chains, cross-node inventory, and higher-fidelity mutable metadata.

Security note: a read-only hostPath mount of a Unix socket does not make the runtime API itself read-only. Direct CRI access must remain opt-in and should be paired with collector AppArmor/SELinux guidance, endpoint/source metrics, and explicit degradation when the socket is unavailable or disabled.

## Docker and Compose Validation

Date: 2026-06-06.

Host `sr-test-pve04` (`192.168.1.62`) has:

- Docker CLI at `/usr/bin/docker`
- Docker Compose CLI available
- `/var/run/docker.sock`
- `/run/containerd/containerd.sock`
- `/var/run/containerd/containerd.sock`

Validation commands:

```sh
docker ps
docker ps -a
docker inspect <container-id>
docker compose ls
docker compose ps
docker events
```

A temporary Compose fixture was validated with a cached `alpine:3.20` image and then removed. The fixture used project `srwi`, service `wi-probe`, a custom ServiceRadar label, a localhost-published port, and a read-only bind mount.

Observed Docker/Compose metadata from `docker inspect` and `docker compose ps --format json`:

- container name: `srwi-wi-probe-1`
- image reference and image digest
- runtime PID from `.State.Pid`
- Compose labels: project, service, container number, config file path, working directory, Compose version, one-off flag, and image digest
- custom labels from the workload
- network name, endpoint ID, container IP, MAC address, aliases, and DNS names
- published port mapping: host IP, host port, target port, protocol
- bind mount source, destination, read-only flag, mode, and propagation

Conclusion: Docker/Compose enrichment can derive useful host/container forensic context from the Docker Engine API without Kubernetes. The production implementation still needs explicit opt-in socket access, sensitive label/mount filtering, and fixture-backed parser tests.

## MVP Packaging Decision

Implement the Kubernetes MVP as a native host add-on first, using the agents already installed on worker nodes. This keeps rollout and commandbus/config-update behavior aligned with the current netprobe add-on model and avoids introducing Kubernetes RBAC for the baseline.

The same binary should keep packaging boundaries clean so it can later run as:

- a Kubernetes DaemonSet for clusters that prefer node-local Kubernetes packaging,
- a Docker Compose service for non-Kubernetes Docker hosts,
- or a least-privileged local metadata helper/proxy when direct runtime socket access is unacceptable.
