## Context
ServiceRadar now has host process attribution for flows, but the forensic surface is still too low-level. A row with `redis-server`, a PID, and a container ID does not tell an operator which pod, namespace, deployment, Docker Compose service, image, or mounted data path they need to inspect.

Modern eBPF agents solve this by joining kernel-visible identity with runtime/orchestrator metadata:
- eBPF provides PID/TGID, UID/GID, comm, cgroup ID/path, netns, socket tuples, and process lifecycle.
- CRI/container runtimes resolve container IDs and sandbox IDs into pod/container names, image references, labels, annotations, and namespace/name/UID fields.
- Kubernetes API or kube-state inventory resolves owner chains and mutable workload metadata that are not fully available from CRI.
- Docker and Compose metadata resolves container names, image digests, labels, networks, ports, mounts, and service/project labels for non-Kubernetes installs.

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

## MVP Packaging Decision
Ship the Kubernetes MVP as a native host add-on first, using the ServiceRadar agents already installed on worker nodes. This matches the current netprobe rollout and commandbus/config-update path, and it avoids broad Kubernetes API/RBAC for the baseline CRI path.

The collector implementation should still keep deployment packaging separate from runtime metadata logic so the same binary can later be delivered as a Kubernetes DaemonSet, Docker Compose service, or least-privileged local metadata helper/proxy.

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

## Security Model
Runtime sockets are powerful. A read-only hostPath mount does not make a Unix socket API read-only. The design must treat CRI/Docker socket access as privileged and auditable.

Controls:
- Socket access is opt-in per deployment.
- Use read-only hostPath mounts for socket paths where the platform supports them, but do not rely on mount mode as the security boundary.
- Provide AppArmor/SELinux profile guidance for the collector and any metadata helper so runtime metadata access is intentionally scoped.
- The collector records which metadata source was used: eBPF-only, CRI, Docker API, containerd, Kubernetes inventory overlay, or fallback.
- Where possible, use a small local metadata proxy/helper that exposes only read methods needed by ServiceRadar instead of giving the main agent full runtime API access.
- Publish degradation counters when metadata sources are unavailable or disabled.
- Never block flow attribution on workload metadata. Missing enrichment must produce explicit unknown/degraded fields.

## Data Flow
1. netprobe attributes flow/socket/process context through eBPF.
2. The workload identity collector keeps node-local caches keyed by process generation, cgroup ID/path, container ID, pod UID, and network namespace.
3. Runtime/orchestrator lookups enrich those keys with workload context.
4. The collector emits bounded workload identity observations to agent-gateway/core.
5. Core stores current identity state and attaches the best known identity to attributed flow records and detail views.

## Non-Goals
- Do not require a pod sidecar in every workload namespace for the baseline implementation.
- Do not grant broad Kubernetes API access to every host agent as the default.
- Do not make procfs scans the source of workload identity.
- Do not retain unbounded raw workload events in CNPG.

## Open Questions
- Should CRI/Docker metadata be joined on the node before upload, or should raw container identity observations be uploaded and joined in core?
- Which labels/annotations are safe and useful by default, and which should require an allowlist to avoid leaking secrets?
- Should the optional Kubernetes inventory overlay integrate with existing discovery/DIRE device identity flows?
- What default correlation window should hold raw flow and workload identity observations for late enrichment, and should high-volume deployments be able to discard unmatched observations immediately after the window closes?
- How do we bound retention so CNPG storage does not grow with high-volume agents, while still preserving enough recent data for incident investigation?
