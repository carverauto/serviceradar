## 1. Discovery and Architecture
- [x] 1.1 Inventory existing netprobe process/container fields, attributed flow query shape, device detail process-listener payloads, and any current container ID parsing helpers.
- [x] 1.2 Validate worker-local CRI metadata on demo Kubernetes nodes: containerd socket path, available pod/container labels, annotations, image IDs, sandbox IDs, runtime PIDs, cgroup paths, and namespace/name/UID fields. Capture quick validation commands such as `crictl pods`, `crictl ps`, `crictl inspect`, and `crictl inspectp` for the runbook, including k3s socket discovery for `/run/k3s/containerd/containerd.sock`.
- [x] 1.2a Add node validation examples for `crictl pods`, `crictl ps`, `crictl inspectp <pod-sandbox-id>`, and `crictl inspect <container-id>` with explicit runtime endpoints for k3s/containerd workers.
- [x] 1.3 Validate Docker/Compose metadata on a non-Kubernetes host: Docker socket availability, Compose labels, container names, image IDs/digests, networks, published ports, and bind mounts. Capture quick validation commands such as `docker ps`, `docker inspect`, `docker compose ps`, and `docker events`. Validated on `sr-test-pve04` with a temporary Compose fixture using cached `alpine:3.20`; Docker exposed Compose project/service/container labels, image digest, runtime PID, network IP/MAC/aliases, localhost-published port, and read-only bind mount metadata.
- [x] 1.4 Decide first packaging target: native host add-on, Kubernetes DaemonSet, Docker Compose service, or one binary with all three manifests.

## 1a. Minimal Viable Milestone
- [x] 1a.1 Implement Kubernetes worker node-local cgroup plus CRI enrichment only, before Docker/Compose and Kubernetes owner overlay work.
- [x] 1a.1a Remove the initial opt-in Kubernetes CRI cache from netprobe startup so netprobe emits socket/process/container join keys only.
- [x] 1a.1b Split cgroup/CRI/cache/runtime metadata code into a standalone `serviceradar-workload-identity` Rust crate so netprobe does not own or link runtime metadata collection.
- [x] 1a.1c Package workload identity as its own native add-on/agent capability so operators can enable container/pod inventory without enabling netprobe flow attribution.
- [x] 1a.1d Add package-managed systemd ownership for ServiceRadar host add-ons: netprobe and workload-identity remain separate units, but share a ServiceRadar slice/target for lifecycle grouping, resource accounting, and status attribution instead of pretending they are child processes of `serviceradar-agent`.
- [x] 1a.1e Put existing native host units (`serviceradar-agent`, netprobe, endpoint-inventory, and bumblebee-scan) in `serviceradar.slice` without adding `PartOf=`, `BindsTo=`, or `Requires=` coupling to `serviceradar-agent.service`.
- [x] 1a.1f Add workload-identity-to-agent forwarding so the standalone collector sends bounded identity observations through agent-gateway/core, where upstream coalesces current-state identity. Netprobe must not be required to consume workload-identity output for the data to reach storage/query/UI.
- [x] 1a.2 Prove the MVP emits namespace, pod name, pod UID, container name, image, node, runtime source, confidence, and degradation reason for attributed flows.
- [x] 1a.2a Carry namespace, pod name, pod UID, container name, image, runtime source, confidence, and degradation reason through protobuf, Rust netprobe events, core staging storage, and OCSF attribution payloads.
- [x] 1a.2b Add operator-provided cluster identity (`cluster_id`, `cluster_name`) to standalone workload-identity snapshots and attributed-flow investigation payloads so multi-cluster deployments can distinguish identical namespace/pod names.
- [ ] 1a.3 Measure CPU, queue lag, source misses, and CNPG write volume for the MVP so workload enrichment does not regress netprobe performance.
- [ ] 1a.4 Choose and document the initial late-enrichment correlation window, including the behavior for unmatched raw observations after the window expires.

## 2. Collector Contract
- [ ] 2.1 Define `WorkloadIdentityBackend` traits/interfaces for eBPF/cgroup identity, CRI/containerd, Docker/Compose, and optional Kubernetes inventory overlay.
- [x] 2.1a Introduce the initial Rust workload identity backend boundary for cgroup parsing and CRI runtime lookups so the Kubernetes MVP can use the same interface before Docker/Compose and overlay backends are added.
- [x] 2.1b Move the initial backend boundary out of `rust/netprobe` into `rust/workload-identity` so future inventory, Docker/Compose, and Kubernetes overlay consumers do not depend on netprobe.
- [ ] 2.2 Define stable workload identity event schema with process generation, cgroup ID/path, netns, container ID, pod UID, namespace, pod/container names, image, labels/annotations, compose service/project, runtime source, and confidence/degradation fields.
- [x] 2.2a Add MVP confidence and degradation fields to the Rust workload identity payload so CRI hits and degraded lookups can be surfaced without changing the payload shape later.
- [x] 2.2b Add workload identity fields to netprobe protobuf messages and flow attribution storage so attributed flows can carry CRI metadata end to end.
- [ ] 2.2c Move the canonical workload identity wire schema out of netprobe-owned protobuf/types. Netprobe may emit stable join keys, but runtime/orchestrator identity must be owned by a workload-identity contract consumed by agent, agent-gateway, core, SRQL, and UI; reserve or deprecate any old netprobe in-band identity fields after the standalone path is proven.
- [ ] 2.3 Add bounded caches, queue limits, drop counters, stale-entry eviction, and source-specific error metrics.
- [x] 2.4 Ensure flow attribution does not block on workload lookups; enrichment must be asynchronous and backfillable when late metadata arrives.

## 3. Kubernetes Node-Local Metadata
- [x] 3.1 Implement CRI/containerd resolver for container ID and pod sandbox ID to pod/container identity using local runtime metadata, with endpoint discovery from explicit config, runtime config files, and common socket paths. Initial CRI endpoint discovery, CRI client wrapper, response normalization tests, and live worker socket validation are implemented.
- [x] 3.1a Evaluate Rust CRI client options against the required CRI v1 calls (`ListPodSandbox`, `PodSandboxStatus`, `ListContainers`, `ContainerStatus`) and prefer CRI-level bindings over containerd-internal APIs so containerd and CRI-O can share the backend.
- [x] 3.1b Prototype a node-local CRI resolver that reproduces the validated `crictl pods`, `crictl ps`, `crictl inspectp`, and `crictl inspect` metadata over the demo worker Unix socket before starting storage or UI work. Validated on `k8s-cp3-worker3` against `/run/k3s/containerd/containerd.sock`, returning running container identities with namespace, pod name/UID, container name, image ref, runtime PID, cgroup path, labels, and annotations. `sr-test-pve04` exposes an older CRI endpoint that returns `runtime.v1.RuntimeService` as unimplemented and remains a separate compatibility follow-up.
- [x] 3.1c Add a first-class Bazel target for the node-local CRI validation helper so worker discovery checks are repeatable outside Cargo-only development.
- [ ] 3.2 Add cgroup v1/v2 parsing and eBPF cgroup/process event joins that do not depend on procfs scans. Initial cgroup pod/container identity parsing is implemented; eBPF join wiring is still pending.
- [ ] 3.3 Package the node-local collector as a Kubernetes DaemonSet or native add-on with explicit host mounts/capabilities and security documentation.
- [ ] 3.4 Add degradation behavior for missing runtime sockets, unsupported runtimes, permission failures, and stale cgroup/container mappings.

## 4. Optional Kubernetes Inventory Overlay
- [ ] 4.1 Design a narrow-RBAC cluster inventory component for owner chains and mutable metadata: namespace, pod, ReplicaSet, Deployment, StatefulSet, DaemonSet, Job, CronJob, and selected labels/annotations.
- [ ] 4.2 Join inventory overlay records by pod UID without requiring every host agent to hold broad Kubernetes API credentials.
- [ ] 4.3 Add label/annotation allowlist controls so sensitive metadata is not ingested by default.

## 5. Docker and Docker Compose Metadata
- [ ] 5.1 Implement Docker/containerd resolver for non-Kubernetes hosts with explicit opt-in socket access.
- [ ] 5.1a Evaluate `bollard` or direct Docker Engine API bindings for container name, image, labels, networks, published ports, bind mounts, and Compose labels.
- [ ] 5.2 Enrich container context with Docker name, image/digest, labels, networks, exposed/published ports, bind mounts, restart policy, runtime source, and host path hints.
- [ ] 5.3 Extract Compose context from labels such as project, service, config files, working directory, and container number when present.
- [ ] 5.4 Provide a least-privileged local metadata helper/proxy option for deployments that do not want the main agent to access the Docker socket directly.

## 6. Storage, Query, and UI
- [ ] 6.1 Add current workload identity state storage with retention for raw observations and durable current-state lookup by container ID, pod UID, cgroup, and process generation.
- [x] 6.1a Add upstream current-state storage for standalone workload identity snapshots keyed by partition, agent, and container ID.
- [ ] 6.2 Attach best-known workload identity to attributed flow records and flow detail views.
- [x] 6.2a Attach best-known node-local CRI workload identity to persisted attributed flow records and correlated flow OCSF payloads.
- [x] 6.2b Join standalone workload-identity current state into the central flow correlator by partition, agent, and container ID, including late backfill for recent attributed flows that were stamped before identity arrived.
- [ ] 6.3 Update attributed flow UI and NetFlow map details to show namespace/pod/workload/container for Kubernetes and project/service/container for Compose.
- [x] 6.3a Show workload cluster identity in attributed flow rows/details when supplied by the workload-identity collector.
- [ ] 6.4 Add filters for namespace, workload owner, pod, container image, Compose project, and Compose service.

## 7. Security and Operations
- [ ] 7.1 Add Helm and Compose configuration knobs for enabling workload identity enrichment and selecting metadata sources.
- [x] 7.1a Remove netprobe add-on/bootstrap workload identity knobs; workload identity enablement, CRI endpoint, and refresh interval belong to the standalone workload-identity add-on.
- [x] 7.1b Add a first-party workload-identity native add-on manifest, config schema, systemd unit, Helm release-import allowlist entry, native add-on bundle inventory entry, and staged package seeder so `/settings/agents/addons` can surface the capability independently of netprobe.
- [x] 7.1c Add Helm core workload-identity add-on artifact/version/OCI knobs so the release/native-add-on import path can approve assignable workload-identity packages without manual environment overrides.
- [x] 7.1d Add workload-identity add-on config fields for explicit cluster identity because CRI/runtime metadata does not reliably expose the Kubernetes cluster name or UID.
- [ ] 7.2 Surface metrics for eBPF identity hits, CRI/Docker hits, overlay hits, misses, stale mappings, socket/API errors, drops, queue lag, cache size, and enrichment latency.
- [ ] 7.3 Document security tradeoffs of CRI/Docker socket access, required Linux capabilities, read-only hostPath mounts where possible, AppArmor/SELinux profiles for the collector/helper, and Kubernetes RBAC for the optional overlay only.
- [ ] 7.4 Add a retention/storage model so workload identity observations do not create another unbounded CNPG hot table.
- [x] 7.5 Add tests for the systemd unit contract: privileged collectors use their own units, share the ServiceRadar slice/target, keep explicit hardening/capabilities, and are surfaced as agent-owned add-ons through status rather than process parentage.

## 8. Verification
- [ ] 8.1 Add unit tests for cgroup/container ID parsing across cgroup v1/v2, containerd, CRI-O, Docker, Kubernetes, and Compose patterns.
- [ ] 8.2 Add integration tests with fixture CRI/Docker responses for Kubernetes and Compose enrichment.
- [x] 8.3 Verify on demo Kubernetes workers that attributed flows show namespace, pod, container name, image, and owner metadata where available.
- [ ] 8.4 Verify on a Docker/Compose host that attributed flows show Compose project/service/container and useful Docker metadata.
- [x] 8.5 Verify standalone ingestion by forwarding a workload-identity snapshot through agent -> agent-gateway -> core without requiring netprobe to consume the snapshot locally.
- [x] 8.6 Run `openspec validate add-workload-identity-enrichment --strict`.
