## ADDED Requirements

### Requirement: Node-local kernel identity correlation
The system SHALL correlate flow/process attribution events with node-local kernel identity keys, including process generation, cgroup identity, network namespace, and container ID, without using periodic procfs scans as the primary source.

#### Scenario: Flow is attributed to a containerized process
- **GIVEN** netprobe observes a flow owned by a process running in a container
- **WHEN** eBPF process/socket/cgroup events identify the process and cgroup
- **THEN** the emitted attribution includes stable keys that can be joined to workload metadata
- **AND** missing workload metadata does not block flow attribution

### Requirement: Kubernetes CRI enrichment
The system SHALL resolve Kubernetes container and pod identity from node-local CRI/runtime metadata before requiring Kubernetes API access.

#### Scenario: CRI maps container ID to pod identity
- **GIVEN** a Kubernetes worker runs containerd or another supported CRI runtime
- **AND** the workload identity collector has access to the local runtime metadata source
- **WHEN** a flow is attributed to a container ID or pod sandbox ID on that node
- **THEN** ServiceRadar records the pod namespace, pod name, pod UID, container name, image reference or image ID, node name, runtime source, and metadata confidence

#### Scenario: Runtime metadata is unavailable
- **GIVEN** runtime socket access is disabled or unavailable
- **WHEN** a flow is attributed to a containerized process
- **THEN** ServiceRadar preserves the process/container ID attribution
- **AND** it records an explicit workload identity degradation reason
- **AND** it increments source-specific miss/error metrics

#### Scenario: Collector discovers non-default CRI endpoint
- **GIVEN** a Kubernetes worker exposes CRI on a non-default runtime socket such as `/run/k3s/containerd/containerd.sock`
- **WHEN** workload identity enrichment starts without an explicit socket override
- **THEN** the collector discovers a supported local CRI endpoint from runtime configuration or common socket paths
- **AND** it records the selected endpoint source in runtime metadata metrics

### Requirement: Minimal viable Kubernetes workload identity
The first workload identity implementation SHALL provide Kubernetes worker-local cgroup plus CRI enrichment before Docker/Compose enrichment or Kubernetes owner-overlay enrichment are required.

#### Scenario: MVP publishes standalone identity
- **GIVEN** workload identity is enabled on a Kubernetes worker
- **AND** local CRI/containerd metadata is available
- **WHEN** the MVP workload identity collector observes container and pod identity
- **THEN** it publishes bounded workload identity observations through the local agent to agent-gateway/core
- **AND** ServiceRadar coalesces current workload identity state without requiring netprobe to consume the observation

#### Scenario: MVP enriches a Kubernetes flow
- **GIVEN** netprobe attributes a flow to a containerized process on a Kubernetes worker
- **AND** local CRI/containerd metadata is available
- **WHEN** ServiceRadar joins the attributed flow with current workload identity state
- **THEN** the resulting flow context includes namespace, pod name, pod UID, container name, image, node, runtime source, confidence, and degradation fields
- **AND** it does not require Kubernetes API credentials on the host agent

### Requirement: Optional Kubernetes inventory overlay
The system SHALL support an optional Kubernetes inventory overlay for owner chains and mutable metadata that CRI does not reliably provide.

#### Scenario: Overlay adds workload owner
- **GIVEN** CRI enrichment has resolved a pod UID
- **AND** the Kubernetes inventory overlay has observed the pod and owner hierarchy
- **WHEN** the flow detail view is rendered
- **THEN** ServiceRadar shows the best known workload owner such as Deployment, StatefulSet, DaemonSet, Job, or CronJob
- **AND** it identifies the overlay as the source for owner metadata

#### Scenario: Host agent lacks Kubernetes API credentials
- **GIVEN** the node-local collector has no Kubernetes API token or RBAC
- **WHEN** CRI metadata is available on the node
- **THEN** baseline namespace/pod/container enrichment still works
- **AND** owner-chain metadata remains absent or is joined from the optional overlay

### Requirement: Docker and Compose enrichment
The system SHALL resolve non-Kubernetes container context for Docker and Docker Compose environments when the operator enables the required metadata source.

#### Scenario: Compose service owns an attributed flow
- **GIVEN** a Docker Compose service emits network traffic
- **AND** workload identity enrichment has access to Docker or runtime metadata
- **WHEN** netprobe attributes the flow to the service container
- **THEN** ServiceRadar records Docker container name, image reference or image ID, Compose project, Compose service, Compose container number, networks, published ports, bind mounts where allowed, runtime source, and metadata confidence

#### Scenario: Docker socket access is not allowed
- **GIVEN** the operator disables Docker socket access
- **WHEN** a Docker or Compose container emits network traffic
- **THEN** ServiceRadar uses eBPF/cgroup-derived container identity where available
- **AND** it marks Docker/Compose metadata as disabled rather than failed

### Requirement: Explicit runtime metadata security boundary
The system SHALL treat CRI and Docker socket access as privileged access that must be explicitly enabled, observable, and replaceable by narrower local helpers.

#### Scenario: Operator enables runtime socket access
- **WHEN** runtime socket access is enabled in Helm or Docker Compose configuration
- **THEN** ServiceRadar documents the required host mounts, Linux capabilities, and socket paths
- **AND** the collector emits metrics identifying which runtime metadata source is active

#### Scenario: Operator uses a local metadata helper
- **GIVEN** an operator does not want the main agent to access the Docker or CRI socket directly
- **WHEN** the local metadata helper is enabled
- **THEN** the main collector consumes only the helper's bounded read-only metadata API
- **AND** flow attribution continues to use the same workload identity schema

### Requirement: Workload identity in flow investigation surfaces
The system SHALL expose workload identity in attributed-flow tables, flow detail views, and NetFlow map drill-downs.

#### Scenario: Kubernetes flow is displayed
- **GIVEN** an attributed flow has Kubernetes workload identity
- **WHEN** an operator opens the attributed flows page or flow details
- **THEN** the UI shows namespace, pod, workload owner when available, container name, image, node, and collecting agent

#### Scenario: Compose flow is displayed
- **GIVEN** an attributed flow has Docker Compose workload identity
- **WHEN** an operator opens the attributed flows page or flow details
- **THEN** the UI shows Compose project, service, container name, image, host, and collecting agent

### Requirement: Bounded storage and late enrichment
The system SHALL store workload identity observations with bounded retention and SHALL support late enrichment of recent attributed flows when metadata arrives after the flow event.

#### Scenario: Metadata arrives after flow attribution
- **GIVEN** a flow is attributed before runtime metadata has been resolved
- **WHEN** workload identity for the same process generation, cgroup, container ID, or pod UID arrives within the configured correlation window
- **THEN** ServiceRadar updates the recent flow investigation record with the best known workload identity
- **AND** the update does not duplicate the flow record

#### Scenario: Raw identity observations expire
- **GIVEN** raw workload identity observations exceed the configured retention window
- **WHEN** retention cleanup runs
- **THEN** expired raw observations are pruned or compacted
- **AND** current workload identity state needed for active flows remains queryable

#### Scenario: Correlation window is bounded
- **GIVEN** workload identity enrichment is enabled for high-volume agents
- **WHEN** raw flow or workload identity observations are held for late enrichment
- **THEN** the retention window is explicitly configurable
- **AND** storage metrics expose raw observation volume and oldest retained observation age

#### Scenario: Workload identity is useful without flow attribution
- **GIVEN** workload identity is enabled for an agent
- **AND** netprobe flow attribution is disabled or not assigned
- **WHEN** the workload identity collector emits observations
- **THEN** ServiceRadar stores current workload identity state for inventory and investigation surfaces
- **AND** no netprobe process is required to forward or persist that identity state
