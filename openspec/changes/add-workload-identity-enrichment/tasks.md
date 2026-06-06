## 1. Discovery and Architecture
- [ ] 1.1 Inventory existing netprobe process/container fields, attributed flow query shape, device detail process-listener payloads, and any current container ID parsing helpers.
- [ ] 1.2 Validate worker-local CRI metadata on demo Kubernetes nodes: containerd socket path, available pod/container labels, annotations, image IDs, sandbox IDs, runtime PIDs, cgroup paths, and namespace/name/UID fields. Capture quick validation commands such as `crictl pods`, `crictl ps`, `crictl inspect`, and `crictl inspectp` for the runbook, including k3s socket discovery for `/run/k3s/containerd/containerd.sock`.
- [ ] 1.3 Validate Docker/Compose metadata on a non-Kubernetes host: Docker socket availability, Compose labels, container names, image IDs/digests, networks, published ports, and bind mounts. Capture quick validation commands such as `docker ps`, `docker inspect`, `docker compose ps`, and `docker events`.
- [ ] 1.4 Decide first packaging target: native host add-on, Kubernetes DaemonSet, Docker Compose service, or one binary with all three manifests.

## 1a. Minimal Viable Milestone
- [ ] 1a.1 Implement Kubernetes worker node-local cgroup plus CRI enrichment only, before Docker/Compose and Kubernetes owner overlay work.
- [ ] 1a.2 Prove the MVP emits namespace, pod name, pod UID, container name, image, node, runtime source, confidence, and degradation reason for attributed flows.
- [ ] 1a.3 Measure CPU, queue lag, source misses, and CNPG write volume for the MVP so workload enrichment does not regress netprobe performance.

## 2. Collector Contract
- [ ] 2.1 Define `WorkloadIdentityBackend` traits/interfaces for eBPF/cgroup identity, CRI/containerd, Docker/Compose, and optional Kubernetes inventory overlay.
- [ ] 2.2 Define stable workload identity event schema with process generation, cgroup ID/path, netns, container ID, pod UID, namespace, pod/container names, image, labels/annotations, compose service/project, runtime source, and confidence/degradation fields.
- [ ] 2.3 Add bounded caches, queue limits, drop counters, stale-entry eviction, and source-specific error metrics.
- [ ] 2.4 Ensure flow attribution does not block on workload lookups; enrichment must be asynchronous and backfillable when late metadata arrives.

## 3. Kubernetes Node-Local Metadata
- [ ] 3.1 Implement CRI/containerd resolver for container ID and pod sandbox ID to pod/container identity using local runtime metadata, with endpoint discovery from explicit config, runtime config files, and common socket paths.
- [ ] 3.2 Add cgroup v1/v2 parsing and eBPF cgroup/process event joins that do not depend on procfs scans.
- [ ] 3.3 Package the node-local collector as a Kubernetes DaemonSet or native add-on with explicit host mounts/capabilities and security documentation.
- [ ] 3.4 Add degradation behavior for missing runtime sockets, unsupported runtimes, permission failures, and stale cgroup/container mappings.

## 4. Optional Kubernetes Inventory Overlay
- [ ] 4.1 Design a narrow-RBAC cluster inventory component for owner chains and mutable metadata: namespace, pod, ReplicaSet, Deployment, StatefulSet, DaemonSet, Job, CronJob, and selected labels/annotations.
- [ ] 4.2 Join inventory overlay records by pod UID without requiring every host agent to hold broad Kubernetes API credentials.
- [ ] 4.3 Add label/annotation allowlist controls so sensitive metadata is not ingested by default.

## 5. Docker and Docker Compose Metadata
- [ ] 5.1 Implement Docker/containerd resolver for non-Kubernetes hosts with explicit opt-in socket access.
- [ ] 5.2 Enrich container context with Docker name, image/digest, labels, networks, exposed/published ports, bind mounts, restart policy, runtime source, and host path hints.
- [ ] 5.3 Extract Compose context from labels such as project, service, config files, working directory, and container number when present.
- [ ] 5.4 Provide a least-privileged local metadata helper/proxy option for deployments that do not want the main agent to access the Docker socket directly.

## 6. Storage, Query, and UI
- [ ] 6.1 Add current workload identity state storage with retention for raw observations and durable current-state lookup by container ID, pod UID, cgroup, and process generation.
- [ ] 6.2 Attach best-known workload identity to attributed flow records and flow detail views.
- [ ] 6.3 Update attributed flow UI and NetFlow map details to show namespace/pod/workload/container for Kubernetes and project/service/container for Compose.
- [ ] 6.4 Add filters for namespace, workload owner, pod, container image, Compose project, and Compose service.

## 7. Security and Operations
- [ ] 7.1 Add Helm and Compose configuration knobs for enabling workload identity enrichment and selecting metadata sources.
- [ ] 7.2 Surface metrics for eBPF identity hits, CRI/Docker hits, overlay hits, misses, stale mappings, socket/API errors, drops, queue lag, cache size, and enrichment latency.
- [ ] 7.3 Document security tradeoffs of CRI/Docker socket access, required Linux capabilities, read-only hostPath mounts where possible, AppArmor/SELinux profiles, and Kubernetes RBAC.
- [ ] 7.4 Add a retention/storage model so workload identity observations do not create another unbounded CNPG hot table.

## 8. Verification
- [ ] 8.1 Add unit tests for cgroup/container ID parsing across cgroup v1/v2, containerd, CRI-O, Docker, Kubernetes, and Compose patterns.
- [ ] 8.2 Add integration tests with fixture CRI/Docker responses for Kubernetes and Compose enrichment.
- [ ] 8.3 Verify on demo Kubernetes workers that attributed flows show namespace, pod, container name, image, and owner metadata where available.
- [ ] 8.4 Verify on a Docker/Compose host that attributed flows show Compose project/service/container and useful Docker metadata.
- [ ] 8.5 Run `openspec validate add-workload-identity-enrichment --strict`.
