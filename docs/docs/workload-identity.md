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

Kubernetes worker enrichment is supported through the local CRI runtime socket. That
path resolves container IDs to pod namespace, pod name, pod UID, container name, and
image without granting ServiceRadar broad Kubernetes API access.

Docker and Docker Compose hosts are supported through a separate Docker Engine socket
backend. The Docker path resolves container ID, container name, image, runtime PID,
labels, and Compose project/service labels when present. If runtime type is left on
auto, the collector tries CRI first and falls back to Docker when Docker Engine is the
available local runtime.

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

Workload context is deployment metadata. In the clean model, set a stable context
name in the add-on assignment or provide it through a small cluster-level operator.
Without that value, the collector can report node-local workload metadata but cannot
safely distinguish two clusters that share namespace and pod names.

Recommended context names are stable, human-meaningful values such as
`prod-us-central-1` or `demo-cp3`. Do not derive workload context from namespace or
pod names alone.

## Docker and Docker Compose model

On non-Kubernetes hosts, Workload Identity reads Docker metadata from the Docker
socket when enabled. Useful fields include:

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
  "context_name": "prod-us-central-1",
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

If `runtime` is omitted or set to `{"type": "auto"}`, the collector discovers common
CRI sockets first and then common Docker sockets such as `/var/run/docker.sock`.

## Recommended rollout sequence

Use a canary before enabling workload enrichment across a cluster:

1. Pick one worker node with known running pods or containers.
2. Confirm the base agent on that node is new enough to install systemd-backed
   add-ons and report their status.
3. Assign `workload-identity` with an explicit `context_name` and runtime socket when
   possible.
4. Confirm `serviceradar-workload-identity.service` is active and the running binary
   resolves to the activated add-on version.
5. Validate the runtime directly with `crictl` or `docker` on the same host.
6. Confirm fresh `in:addon_statuses addon_id:workload-identity` rows.
7. Confirm workload rows include useful operator fields such as namespace, pod,
   container name, image, Compose project/service, or Docker labels depending on the
   runtime.
8. Expand to the rest of the cluster or Docker cohort.

If multiple Kubernetes clusters or container environments report into the same
ServiceRadar deployment, treat `context_name` as required operational metadata.
Namespace and pod names are not unique across clusters.

## Emitted fields

Field coverage depends on the runtime source. Use this as the expected baseline:

| Field | Kubernetes CRI | Docker / Compose | Notes |
| --- | --- | --- | --- |
| Container ID | Yes | Yes | Primary join key for containerized processes. |
| Container name | Yes | Yes | Docker Compose names may include project and replica suffixes. |
| Image | Yes | Yes | Digest availability depends on runtime metadata. |
| Namespace | Yes | No | Kubernetes namespace from pod sandbox metadata. |
| Pod name / UID | Yes | No | Requires CRI pod sandbox lookup. |
| Workload owner | Optional context overlay | No | Deployment/StatefulSet/DaemonSet owner usually requires Kubernetes API or operator metadata. |
| Context name | Assignment or overlay | Assignment | CRI does not expose kubeconfig context names or another reliable global context identity. |
| Compose project/service | No | Yes, when labels exist | Uses standard Compose labels. |

The collector should publish bounded snapshots and lifecycle changes to the local
spool directory. The base agent reads those snapshots and sends them to the gateway;
netprobe is not required to consume them locally.

The normal data path is:

```text
runtime/cgroup metadata -> workload-identity -> local spool
local spool -> base agent -> agent-gateway -> core workload current state
core workload current state -> flow details, attributed flows, inventory surfaces
```

This path is intentionally independent from netprobe. A deployment can use Workload
Identity for container inventory without host flow attribution, and a deployment can
use netprobe on bare-metal hosts without any container runtime metadata.

## Validation

On a host:

```bash
sudo systemctl status serviceradar-workload-identity.service
sudo journalctl -u serviceradar-workload-identity.service -n 100 --no-pager
readlink -f /var/lib/serviceradar/agent/addons/workload-identity/current
readlink -f /proc/$(pidof serviceradar-workload-identity)/exe
sudo find /var/lib/serviceradar/workload-identity/spool -maxdepth 1 -type f -ls | tail
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

Useful SRQL checks:

```text
in:addon_statuses addon_id:workload-identity sort:reported_at:desc limit:50
in:attributed_flows time:last_1h attribution_status:attributed sort:time:desc limit:50
in:attributed_flows time:last_1h workload_namespace:demo sort:time:desc limit:50
```

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
- The base agent release is new enough to report systemd-backed add-on status and
  ingest workload identity snapshots.
- `context_name` is set when multiple Kubernetes contexts or container
  environments report into the same ServiceRadar deployment.

### Context name is missing

Set `context_name` in the assignment or deploy the optional context overlay. Node-local
CRI data can usually identify namespace and pod, but kubeconfig context names are not
reliably available from the runtime socket alone.

### Docker host reports CRI errors

Docker-only and Docker Compose hosts do not necessarily expose CRI v1. If an older
collector logs an error such as `unknown service runtime.v1.RuntimeService`, update to
a workload-identity add-on version with Docker backend support or set the assignment
runtime to:

```json
{
  "runtime": {
    "type": "docker",
    "socket": "/var/run/docker.sock"
  }
}
```

Docker hosts will not have Kubernetes pod or namespace fields unless an additional
orchestration overlay supplies them. They should still show container name, image,
runtime PID, labels, and Compose project/service labels.

### Multiple contexts look identical

CRI data is node-local and does not contain a durable global context identity. Set
`context_name` in the add-on assignment for every Kubernetes context or container
environment, or deploy an overlay that stamps context metadata onto the node-local
collector config. Without that, two contexts can legitimately produce the same
namespace, pod, and container names.

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
