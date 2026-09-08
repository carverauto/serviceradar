## Context
ServiceRadar now has host process attribution for flows, but the forensic surface is still too low-level. A row with `redis-server`, a PID, and a container ID does not tell an operator which pod, namespace, deployment, Docker Compose service, image, or mounted data path they need to inspect.

Modern eBPF agents solve this by joining kernel-visible identity with runtime/orchestrator metadata:
- eBPF provides PID/TGID, UID/GID, comm, cgroup ID/path, netns, socket tuples, and process lifecycle.
- CRI/container runtimes resolve container IDs and sandbox IDs into pod/container names, image references, labels, annotations, and namespace/name/UID fields.
- Kubernetes API or kube-state inventory resolves owner chains and mutable workload metadata that are not fully available from CRI.
- Docker and Compose metadata resolves container names, image digests, labels, networks, ports, mounts, and service/project labels for non-Kubernetes installs.

This follows the same broad deployment model used by Cilium/Tetragon, Falco, Tracee, and similar agents: one node-local collector does the kernel/runtime join for everything on that node, while optional cluster-level components add owner-chain or inventory context. ServiceRadar should keep that separation explicit so baseline enrichment stays node-local and does not require every worker agent to hold Kubernetes API credentials.

## Decision
Build a shared workload identity collector contract with deployment-specific packaging:

- Kubernetes: run node-local as a privileged DaemonSet or native host add-on on each worker. It reads eBPF/kernel context and local CRI/runtime metadata from the node. It does not need broad Kubernetes API access for the baseline pod/container identity path.
- Docker/Compose: run as the host agent add-on or sidecar service. It reads eBPF/kernel context plus Docker/containerd metadata when explicitly enabled.
- Optional Kubernetes inventory overlay: add a separate cluster component with narrow RBAC to watch pods, replica sets, deployments, stateful sets, daemon sets, jobs, namespaces, and selected labels/annotations. This component publishes signed inventory snapshots that node-local collectors or core can join by pod UID.

## Minimal Viable Milestone
The first implementation should stop at node-local cgroup plus CRI enrichment on Kubernetes workers:
- Join eBPF process/socket/cgroup identity to local CRI/containerd metadata.
- Emit namespace, pod name, pod UID, container name, image, node, runtime source, and degradation fields.
- Surface that context on attributed flow rows/details.
- Prove CPU, queue lag, and CNPG write volume stay within the netprobe performance budget.

Docker/Compose metadata and the optional Kubernetes inventory overlay are follow-on milestones that reuse the same schema and backend boundary.

This milestone should be implementation-gated separately from the broader workload identity plan. Do not block the Kubernetes CRI/cgroup MVP on Docker, Compose, owner-chain overlay, cold storage, or cluster-wide inventory work.

The MVP acceptance test should be narrow: on a demo Kubernetes worker, standalone workload identity observations must reach agent-gateway/core and a containerized attributed flow must show pod namespace, pod name, pod UID, container name, image, node, runtime source, confidence, and explicit degradation fields without granting Kubernetes API credentials to the host agent.

## MVP Packaging Decision
Ship the Kubernetes MVP as a standalone workload-identity capability first, using the ServiceRadar agents already installed on worker nodes. Netprobe is an optional consumer of this capability, not the owner of CRI, Docker, Compose, or Kubernetes metadata. This avoids broad Kubernetes API/RBAC for the baseline CRI path while keeping workload identity useful for customers that want container/pod inventory even when flow attribution is disabled.

The collector implementation should keep deployment packaging separate from runtime metadata logic so the same library and binary can later be delivered as a native add-on, Kubernetes DaemonSet, Docker Compose service, or least-privileged local metadata helper/proxy.

The Rust boundary should live outside netprobe. Netprobe MUST NOT own CRI, Docker, Compose, or Kubernetes metadata clients, and it MUST NOT require the workload identity collector to be running. Netprobe emits stable socket/process/container join keys; the workload identity crate owns cgroup parsing, CRI/Docker client behavior, runtime metadata caches, degradation states, and validation tooling.

The ingestion contract must not make workload identity dependent on netprobe consuming it. The workload identity collector publishes compact identity snapshots/events to the local ServiceRadar agent, the agent forwards them through agent-gateway, and core coalesces current identity state plus any bounded raw observations needed for late joins. Netprobe emits stable socket/process/container join keys only; upstream correlation is the golden path so workload identity is useful without flow attribution and flow attribution can be enriched after delayed metadata arrives.

The canonical workload identity schema should also move out of netprobe-owned wire/types. Netprobe was the first attribution producer, so early MVP fields landed in the netprobe protobuf, but the long-term contract belongs to workload identity and upstream correlation. The stable model is: workload identity owns runtime/orchestrator metadata, netprobe owns flow/socket/process join keys, and core/SRQL/UI join those independent streams. Once the standalone path is proven in demo, old netprobe in-band workload identity fields should be reserved or deprecated so future collectors do not inherit a false netprobe dependency.

Native host packaging should model workload identity and netprobe as ServiceRadar-owned peers, not as process children of the agent. Long-running privileged collectors should remain separate systemd units so restart policy, Linux capabilities, hardening, and cgroup accounting are explicit. To make ownership visible, package-managed units should share a ServiceRadar systemd slice or target (for example `serviceradar.slice` / `serviceradar-agent.target`) and report add-on ownership through agent status, while the agent attaches to collector IPC instead of supervising privileged processes directly.

For the native CRI MVP, workload identity runs as its own sandboxed root systemd service because real worker sockets such as `/run/k3s/containerd/containerd.sock` are commonly `root:root 0660`. This does not make the agent a privileged supervisor and does not make netprobe a dependency. A later least-privileged local metadata proxy can reduce that privilege boundary, but the first native add-on must be able to read the node-local runtime socket when explicitly enabled.

## Key Point: CRI Is Enough For Baseline Pod Identity
On Kubernetes workers, local CRI metadata is usually enough to map a container ID or pod sandbox ID to:
- pod name
- pod namespace
- pod UID
- container name
- image reference/image ID
- selected labels/annotations exposed by the runtime

That means the first implementation can avoid broad Kubernetes API credentials on the host agent. The tradeoff is that CRI is not the best source for higher-level owner chains such as Deployment -> ReplicaSet -> Pod, and it may not reflect all mutable label/annotation changes with the same fidelity as a Kubernetes watch.

Because ServiceRadar agents are already installed directly on the worker nodes in the demo environment, the MVP can access the node's local containerd CRI socket directly when the operator enables that source. This should be treated as privileged node-local runtime access, not as a Kubernetes API integration. No Kubernetes RBAC is required for the baseline namespace/pod/container identity path, but socket access still needs explicit configuration, auditing, and degradation metrics.

The collector must discover the CRI endpoint instead of assuming the default containerd socket. Demo k3s workers expose the runtime at `/run/k3s/containerd/containerd.sock`, while many standard kubeadm/containerd nodes use `/run/containerd/containerd.sock` or `/var/run/containerd/containerd.sock`; CRI-O commonly uses `/var/run/crio/crio.sock`. Endpoint selection should prefer an explicit config value, then known runtime config files, then a bounded list of common socket paths.

Live validation on `k8s-cp3-worker3` showed that node-local `crictl` can resolve:
- pod sandbox ID -> namespace, pod name, pod UID, pod labels, pod annotation keys, and sandbox cgroup path
- container ID -> container name, image reference, pod labels, pod UID, runtime PID, and container cgroup path

That is enough for the minimal viable enrichment path without Kubernetes RBAC on the host agent.

## Runtime Client Implementation Notes
The Kubernetes MVP should query the node-local CRI API, not the Kubernetes API, for baseline pod/container identity. In Rust, evaluate existing containerd/CRI client crates against the current CRI v1 methods we need, especially list/status calls equivalent to `crictl pods`, `crictl ps`, `crictl inspectp`, and `crictl inspect`. If an existing crate does not expose the required CRI surface cleanly, generate the minimal protobuf bindings needed for the runtime service instead of binding the collector to containerd internals.

The resolver should prefer CRI-level pod sandbox and container status data over containerd-only metadata so the same backend can support containerd and CRI-O. Docker and Docker Compose support should be a later backend, likely using the Docker Engine API or a Rust Docker client, and should not block the Kubernetes cgroup plus CRI MVP.

Implementation candidates:
- Generated CRI v1 `tonic`/`prost` bindings for `ListPodSandbox`, `PodSandboxStatus`, `ListContainers`, and `ContainerStatus` are the preferred portable path if no crate exposes the needed API cleanly.
- `containerd-client` can be evaluated for containerd environments, but the ServiceRadar backend should not depend on containerd-only APIs for Kubernetes baseline enrichment. Prefer the CRI service surface even when talking to containerd so CRI-O remains a compatible backend.
- `bollard` is the likely Docker Engine API candidate for Docker and Compose enrichment after the CRI/cgroup MVP.

The first client spike should reproduce the validated `crictl` calls over the worker's Unix socket and return a small in-memory map of container ID and pod sandbox ID to namespace, pod name, pod UID, container name, image, runtime PID, and cgroup path. Schema, storage, and UI work should wait until that node-local resolver behavior is proven against the demo k3s/containerd socket.

## Node Validation Commands
Use `crictl` as the operator/debug equivalent of the MVP CRI calls. On k3s/containerd workers:

```bash
sudo crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock pods
sudo crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock ps
sudo crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock inspectp <pod-sandbox-id>
sudo crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock inspect <container-id>
```

On standard containerd workers, use the discovered endpoint, commonly:

```bash
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps
```

For Docker/Compose follow-up validation:

```bash
docker ps --no-trunc
docker inspect <container-id>
docker compose ps
docker events --since 10m
```

## Security Model
Runtime sockets are powerful. A read-only hostPath mount does not make a Unix socket API read-only. The design must treat CRI/Docker socket access as privileged and auditable.

Controls:
- Socket access is opt-in per deployment.
- Native host packaging runs the standalone workload identity collector as a tightly sandboxed root service by default because Kubernetes CRI sockets are commonly `root:root 0660`. This privilege belongs to the collector unit, not to `serviceradar-agent` and not to netprobe.
- Use read-only hostPath mounts for socket paths where the platform supports them, but do not rely on mount mode as the security boundary.
- Provide AppArmor/SELinux profile guidance for the collector and any metadata helper so runtime metadata access is intentionally scoped.
- The collector records which metadata source was used: eBPF-only, CRI, Docker API, containerd, Kubernetes inventory overlay, or fallback.
- Where possible, use a small local metadata proxy/helper that exposes only read methods needed by ServiceRadar instead of giving the main agent full runtime API access.
- Publish degradation counters when metadata sources are unavailable or disabled.
- Never block flow attribution on workload metadata. Missing enrichment must produce explicit unknown/degraded fields.

The optional Kubernetes inventory overlay is the only component that should need Kubernetes API RBAC. The baseline node-local CRI/cgroup path must work without Kubernetes API access on the host agent.

## Data Flow
1. Netprobe attributes flow/socket/process context through eBPF and emits stable join keys such as process generation, container ID, socket tuple, and network namespace when available. It does not own or forward runtime/orchestrator metadata.
2. The workload identity collector independently keeps node-local caches keyed by process generation, cgroup ID/path, container ID, pod UID, and network namespace.
3. Runtime/orchestrator lookups enrich those keys with workload context.
4. The collector emits bounded workload identity observations to the local agent, which forwards them through agent-gateway to core.
5. Core coalesces current identity state, keeps only bounded raw observations needed for late joins, and attaches the best known identity to attributed flow records and detail views.
6. Netprobe is not a required hop in the workload identity data path. If a future optimization adds node-local pre-join behavior, it must consume the same bounded identity contract as any other component and must not replace the agent -> agent-gateway -> core coalescing path.

## Non-Goals
- Do not require a pod sidecar in every workload namespace for the baseline implementation.
- Do not grant broad Kubernetes API access to every host agent as the default.
- Do not make procfs scans the source of workload identity.
- Do not retain unbounded raw workload events in CNPG.

## Open Questions
- Do we need any node-local pre-join optimization after measuring upstream correlation latency, and if so how do we keep it from becoming a second workload identity ingestion path?
- Which labels/annotations are safe and useful by default, and which should require an allowlist to avoid leaking secrets?
- Should the optional Kubernetes inventory overlay integrate with existing discovery/DIRE device identity flows?
- What default correlation window should hold raw flow and workload identity observations for late enrichment, such as 1 minute, 5 minutes, or 15 minutes, without bloating CNPG storage?
- Should high-volume deployments be able to discard unmatched observations immediately after the correlation window closes, while keeping only matched/enriched investigation records?
- How do we bound retention so CNPG storage does not grow with high-volume agents, while still preserving enough recent data for incident investigation?
