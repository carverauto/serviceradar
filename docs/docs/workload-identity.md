---
sidebar_position: 18
title: Workload Identity
---

# Workload Identity

Workload Identity is a standalone native add-on that enriches host process and
network events with the workload context operators need during incident response:
cluster, namespace, pod, workload owner, container name, image, runtime labels, and
container ID.

It is intentionally independent from `serviceradar-netprobe`. Deploy it when you want
container and workload inventory, even if you are not collecting host network flows.
When both add-ons are enabled, ServiceRadar joins Workload Identity metadata with
attributed flows upstream.

## Why it is separate from netprobe

Process attribution and workload metadata have different lifecycles:

- `netprobe` observes sockets, packets, and process attribution.
- Workload Identity observes container runtime and orchestration metadata.
- The base agent owns assignment, config delivery, artifact verification, status, and
  transport to the gateway.
- The core pipeline coalesces events by host, PID generation, cgroup/container ID,
  runtime ID, and time.

This split avoids making flow attribution a prerequisite for workload inventory and
keeps runtime-specific integrations out of the packet-capture hot path.

## Data sources

The collector prefers node-local sources:

- **Cgroups and process metadata** provide container ID and PID-to-cgroup hints.
- **CRI runtime sockets** resolve container IDs to pod sandbox, namespace, pod UID,
  container name, image, labels, and annotations on Kubernetes nodes.
- **Docker Engine socket/events** provide container names, Compose project/service,
  image, labels, and lifecycle state on Docker and Docker Compose hosts.
- **Optional orchestration overlay** may add cluster ID, workload owner, and richer
  metadata when a deployment chooses to run a Kubernetes operator/controller.

The minimal viable path is cgroup plus CRI enrichment on each worker node. It does not
require broad Kubernetes API access by default.

## Current implementation status

The first supported path is Kubernetes worker enrichment through the local CRI
runtime socket. That path resolves container IDs to pod namespace, pod name, pod UID,
container name, and image without granting ServiceRadar broad Kubernetes API access.

Docker and Docker Compose metadata are part of the target design, but they should be
treated as a separate runtime backend. On a host where the configured socket does not
serve the CRI v1 RuntimeService, the collector should report a degraded runtime-source
state rather than pretending Kubernetes metadata is available. Future Docker support
should use Docker's socket/events and Compose labels instead of the CRI client.

## Kubernetes model

On Kubernetes workers, run the add-on on every node that runs ServiceRadar agents or
netprobe. The collector reads the local CRI socket, usually one of:

```text
/run/containerd/containerd.sock
/var/run/containerd/containerd.sock
/var/run/crio/crio.sock
```

For quick validation on a node, use `crictl` against the same socket:

```bash
sudo crictl pods
sudo crictl ps
sudo crictl inspect <container-id>
sudo crictl inspectp <pod-sandbox-id>
```

Cluster identity is deployment metadata. In the clean model, set a stable cluster ID
in the add-on assignment or provide it through a small cluster-level operator. Without
that value, the collector can report node-local workload metadata but cannot safely
distinguish two clusters that share namespace and pod names.

Recommended cluster IDs are stable, human-meaningful values such as
`prod-us-central-1` or `demo-cp3`. Do not derive cluster identity from namespace or
pod names alone.

## Docker and Docker Compose model

On non-Kubernetes hosts, Workload Identity reads Docker metadata from the Docker
socket or event stream when enabled. Useful fields include:

- Container ID and container name.
- Image repository, tag, and digest when available.
- Docker labels.
- Compose project, service, and one-off container markers.
- Network namespace and exposed/listening ports when available.

Docker socket access is privileged. Mount it read-only where the platform permits,
and prefer the narrowest collector mode that satisfies the deployment.

## Security model

Workload Identity needs access to sensitive local runtime metadata. Treat it as a
privileged host collector:

- Run it as a separate systemd service under `serviceradar.slice`.
- Mount runtime sockets read-only where possible.
- Use AppArmor or SELinux profiles where the host policy supports them.
- Avoid broad Kubernetes API credentials by default.
- Prefer node-local CRI and Docker lookups for the first enrichment pass.
- Surface degradation counters when runtime sockets are unavailable or metadata joins
  are incomplete.

## Configuration

Enable the add-on from **Settings > Agents > Add-ons** after approval. A minimal
Kubernetes worker assignment should include:

```json
{
  "enabled": true,
  "cluster_id": "prod-us-central-1",
  "runtime": {
    "type": "containerd",
    "socket": "/run/containerd/containerd.sock"
  }
}
```

A Docker Compose host can use:

```json
{
  "enabled": true,
  "runtime": {
    "type": "docker",
    "socket": "/var/run/docker.sock"
  }
}
```

## Validation

On a host:

```bash
sudo systemctl status serviceradar-workload-identity.service
sudo journalctl -u serviceradar-workload-identity.service -n 100 --no-pager
```

For Kubernetes/containerd:

```bash
sudo crictl pods | head
sudo crictl ps | head
```

For Docker:

```bash
sudo docker ps --format '{{.ID}} {{.Names}} {{.Image}}'
sudo docker inspect <container-id> --format '{{json .Config.Labels}}'
```

In ServiceRadar, validate that attributed flow details and process listener views show
namespace, pod, container name, image, and cluster where available.

For a quick database-side smoke check in an operational tools pod, verify recent
workload rows by agent:

```sql
SELECT agent_id, count(*) AS workloads, max(observed_at) AS newest
FROM platform.workload_identity_current
GROUP BY agent_id
ORDER BY agent_id;
```

For attributed-flow joins, inspect whether process attribution rows have container
IDs and whether the same container IDs exist in `workload_identity_current`. A
container ID present in both tables but missing from the UI usually indicates an
upstream join or backfill problem rather than a node collector problem.

## Troubleshooting

### Workload is blank for a process

Check:

- The collector is installed and active on the same host.
- The runtime socket path matches the host runtime.
- The process is inside a container cgroup.
- The container was still known to the runtime when enrichment ran.
- The event is inside the configured metadata retention/correlation window.

### Cluster name is missing

Set `cluster_id` in the assignment or deploy the optional cluster overlay. Node-local
CRI data can usually identify namespace and pod, but cluster identity is not reliably
available from the runtime socket alone.

### Docker host reports CRI errors

Docker-only and Docker Compose hosts do not necessarily expose CRI v1. If the service
logs an error such as `unknown service runtime.v1.RuntimeService`, point the
assignment at a supported runtime backend for that host. Until the Docker backend is
enabled, Kubernetes-style workload fields are not expected on that host.

### Container ID exists but pod metadata is missing

Use `crictl inspect` and `crictl inspectp` on the node. If CRI returns the sandbox and
container metadata, the problem is likely in collector parsing or upstream join
timing. If CRI does not return it, the container may have exited before enrichment or
the collector may be pointed at the wrong runtime socket.

## Relationship to attributed flows

Attributed flows combine multiple streams:

- NetFlow or host flow observations provide the network tuple and traffic counters.
- `netprobe` provides process/socket attribution.
- Workload Identity provides runtime and orchestration metadata.
- Core joins the streams and exposes them through SRQL, flow details, and dashboard
  map enrichment.

This means Workload Identity improves more than one UI surface. It is useful for
agent inventory, process listeners, flow forensics, and future workload-level search,
even when a deployment does not enable host flow capture.

## Retention and scale

Workload identity is state-like metadata, not a high-cardinality packet stream. The
collector should publish bounded snapshots and lifecycle changes, while the core keeps
the latest identity by partition, agent, and container ID. Historical retention should
be long enough to enrich delayed flow and process events, but short enough to avoid
turning runtime inventory into an unbounded forensic log.

For high-volume clusters, watch these classes of metrics:

- Runtime list/inspect latency and failures.
- Snapshot size by node and runtime source.
- Queue lag and dropped metadata updates.
- Current workload rows by agent.
- Attributed-flow rows with container ID but missing workload identity.
