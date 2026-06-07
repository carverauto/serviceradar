# Change: Add workload identity enrichment

## Why
Netflow-to-process attribution currently shows process and container identifiers, but that is not enough for forensics. Operators need to know which Kubernetes namespace/pod/workload or Docker Compose service actually owned the process that talked on the network.

## What Changes
- Add a workload identity enrichment capability that correlates eBPF-visible process, cgroup, network namespace, and socket context with runtime and orchestrator metadata.
- Support Kubernetes workers through node-local CRI/runtime metadata first, without requiring broad Kubernetes API access for the host agent.
- Stage the minimal viable implementation as Kubernetes cgroup plus CRI enrichment only before Docker/Compose or Kubernetes inventory-overlay work.
- Package workload identity as an independent add-on whose data path is collector -> agent -> agent-gateway -> core; netprobe can consume the context opportunistically but is not required for ingestion, storage, query, or UI.
- Support Docker and Docker Compose hosts through Docker/containerd metadata, Compose labels, container names, images, networks, ports, and mounts.
- Define an optional cluster inventory overlay for Kubernetes owner chains, mutable labels/annotations, and workload-level metadata that CRI alone cannot reliably provide.
- Publish bounded, signed workload identity observations to ServiceRadar so attributed flows, device details, and flow detail views can show actionable workload context.

## Impact
- Affected specs: workload-identity-enrichment
- Affected code: netprobe/native add-ons, agent or node-local collector packaging, agent-gateway/core ingestion, attributed flow storage/query shape, web-ng flow/detail UI
- Security impact: CRI/Docker socket access must be explicitly enabled, auditable, and replaceable with least-privileged local metadata helpers where socket access is unacceptable.
