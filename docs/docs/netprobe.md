---
sidebar_position: 17
title: Host Network Visibility
---

# Host Network Visibility

Host Network Visibility uses the `serviceradar-netprobe` native add-on to observe
host network activity, attribute flows to local processes, and emit evidence that
ServiceRadar can join with NetFlow records, passive fingerprints, workload metadata,
and threat intelligence.

`netprobe` is a privileged Rust service. It is intentionally separate from the base
`serviceradar-agent`: the agent assigns, verifies, configures, and reports the add-on,
while `netprobe` owns host-level packet and socket collection.

Process-to-flow attribution is the add-on itself. Assign netprobe with
`enabled: true` and it attaches host-wide eBPF kprobes; that path does not
wait for a Visibility Profile. Packet capture, DPI, and fingerprinting are
the extra policy surface: operators set those in
[Visibility Profiles](./visibility-profiles.md)
(`Settings -> Network Services -> Visibility Profiles`), which name the NIC
and target devices. Assign netprobe first. Add a profile only when you want
passive capture on a real interface.

## What netprobe does

`serviceradar-netprobe` provides three related data streams:

- **Flow observations.** Low-overhead host flow capture and classification for local
  traffic that may not be visible to external NetFlow exporters.
- **Process attribution.** Kernel-derived socket/process context, including PID,
  TGID, UID, GID, process name, and the socket tuple used for correlation.
- **Passive evidence.** Host network evidence that can feed device fingerprinting and
  later enrichment layers.

The central pipeline joins these observations with NetFlow rows. This keeps raw host
observations available long enough for delayed NetFlow batches, but avoids requiring
every worker node to receive every NetFlow observation and perform the join locally.

Use this add-on when you need to answer questions such as:

- Which process on this worker owned one endpoint of a NetFlow conversation?
- Which agent observed the process evidence used for the join?
- Did a NetFlow row match process attribution, workload identity, or threat intel?
- Is the host collector dropping events, falling back to cold metadata reads, or
  running above the expected CPU budget?

## eBPF and AF_XDP roles

`netprobe` uses eBPF for process and socket attribution. eBPF programs publish
socket lifecycle and process context into bounded maps/ring buffers, which the Rust
service consumes into an in-memory attribution cache. This is the primary source for
PID/TGID/UID/GID/comm/socket tuples and avoids hot-path `/proc/net/tcp` walks.

AF_XDP is used for low-overhead packet/flow capture and classification where enabled
and supported by the host interface. AF_XDP does not identify the owning process by
itself; it supplies efficient packet/flow visibility that user space correlates with
the eBPF attribution cache.

Cold-path `/proc` reads are reserved for metadata that the kernel events do not carry
directly, such as process command line and cgroup/container hints. These reads must be
bounded, cached by PID generation, and surfaced through degradation metrics so an
operator can see when enrichment falls back or is incomplete.

## Deployment model

For pushed-artifact add-on installs, the active binary is loaded through the add-on
activation symlink:

```bash
/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe
```

Production deployments should run it as a native add-on systemd unit under
`serviceradar.slice`, not as a child process of `serviceradar-agent`. The agent still
owns desired state: assignment, artifact verification, config delivery, health
reporting, and drift detection.

On Kubernetes worker nodes, run `netprobe` on the host where the agent is installed.
It observes the node kernel and host interfaces. Workload, pod, namespace, and image
metadata are provided by the separate [Workload Identity](./workload-identity.md)
add-on and are joined upstream.

Do not assign `netprobe` to the in-cluster `k8s-agent` pod. That identity does not
own the worker kernel, systemd, BPF filesystem, host interfaces, or netprobe
bootstrap config path. Target the ServiceRadar agent installed on each worker node
instead.

The base agent reports desired and observed add-on state to ServiceRadar, but it does
not supervise `netprobe` as a child process. The expected host shape is:

```text
serviceradar.slice
  serviceradar-agent.service
  serviceradar-netprobe.service
  serviceradar-workload-identity.service
```

This keeps BPF/network privileges and CPU accounting isolated from the base agent.

## Requirements

- Linux agent hosts.
- A ServiceRadar release that includes the `netprobe` native add-on artifact.
- Kernel support for eBPF maps/ring buffers and BTF where required by the loaded
  programs.
- Host privileges for packet capture and BPF loading, typically a constrained
  combination of `CAP_BPF`, `CAP_NET_ADMIN`, `CAP_NET_RAW`, and access to bpffs and
  cgroup metadata. Older kernels may require broader capabilities.
- Explicit capture interface allowlist. Avoid `any` and wildcard interface names.
- Open firewall path from the agent host to the configured ServiceRadar gateway.

List host interfaces before enabling capture:

```bash
ip -o link show
```

## Configuration

Enable the add-on from **Settings > Agents > Add-ons** after the package has been
approved. Target individual agents or a cohort and provide the add-on parameters
validated by the package schema. `enabled: true` is enough for process
attribution and `in:attributed_flows`. Add a
[Visibility Profile](./visibility-profiles.md) only when you also want
per-device packet capture, DPI, or fingerprint bindings.

A minimal host configuration should include:

```json
{
  "enabled": true,
  "capture_interfaces": ["eth0"],
  "flow_attribution_ipc_batch": true,
  "emit_raw_flow_attribution_events": true
}
```

`enabled` turns on eBPF process attribution. `capture_interfaces` is optional and is
only needed for passive packet capture, DPI, and fingerprinting; an empty list still
allows process attribution. `flow_attribution_ipc_batch` should stay enabled unless
you are debugging an older agent framing problem. `emit_raw_flow_attribution_events`
keeps the central join path fed with process observations for delayed NetFlow rows.

Keep raw observations enabled when you want central NetFlow-to-process joins. If a
deployment only wants local host telemetry and does not retain unmatched observations,
configure the upstream retention/discard policy in the chart or control plane rather
than disabling process attribution at the edge.

For large fleets, prefer assigning by cohort or control-plane-derived host inventory.
Do not maintain static per-agent host-slice lists in Helm values for production-scale
deployments.

## Recommended rollout sequence

Use a staged rollout for host network visibility:

1. Assign `netprobe` to one canary host that already has NetFlow involving that host.
2. Confirm `serviceradar-netprobe.service` is active and the running binary resolves
   to the activated add-on version.
3. Confirm fresh `in:addon_statuses addon_id:netprobe` rows for the canary.
4. Confirm `in:attributed_flows` shows new rows from that agent and includes TCP,
   UDP, or ICMP coverage expected for the traffic being tested.
5. Check `pidstat` and the add-on metrics endpoint for sustained CPU, drops, queue
   lag, stale entries, and duplicate suppression.
6. Expand to a small worker cohort, then to the full target fleet.

Do not treat a low CPU number alone as success. A healthy rollout also has bounded
ring-buffer lag, stable cache size, low drop counters, and an attribution hit rate
that matches the traffic and NetFlow visibility available to ServiceRadar.

## Data model and query surfaces

`netprobe` evidence is consumed by the central attribution pipeline and exposed in:

- `in:attributed_flows` SRQL queries for joined NetFlow/process rows.
- NetFlow flow details when an attributed process match exists.
- Dashboard NetFlow map popovers when a flow path has attribution evidence.
- Agent/device details through process listener and add-on status surfaces.

The central join uses the flow tuple, protocol, agent/host ownership, process
metadata, optional container ID, and workload identity metadata. When a flow
endpoint is a Kubernetes public VIP (LoadBalancer / Gateway / ExternalIP), core
also consults [public endpoint inventory](./k8s-public-endpoint-inventory.md)
to map `VIP:port → podIP:targetPort` and match netprobe on the **post-DNAT**
backend socket, then stamps `attribution.public_endpoint` (Service, Gateway,
route, namespace) onto the attributed flow. TCP, UDP, and ICMP rows may appear
in attributed flows; ICMP uses protocol-specific matching because it does not
have TCP/UDP ports.

The normal data path is:

```text
netprobe -> base agent -> agent-gateway -> core -> attributed flow current state
NetFlow collector -> core ------------------------------------------^
Workload Identity -> base agent -> agent-gateway -> core -----------^
k8s-inventory -> NATS -> EventWriter -> public_endpoints_current ---^
```

The join happens centrally so ServiceRadar can retain enough host evidence for
delayed NetFlow batches and can enrich the same flow record with workload identity,
public VIP ownership, reverse DNS, service-port mapping, threat intelligence, and
future investigation signals. The edge collector should suppress duplicate
observations and keep queues bounded, but it should not be responsible for
fleet-wide joins. Host agents never need Kubernetes API credentials for VIP
ownership—that stays on the in-cluster inventory Deployment.

Common SRQL entry points:

```text
in:attributed_flows time:last_1h attribution_status:attributed sort:time:desc limit:50
in:attributed_flows time:last_1h protocol_name:udp sort:time:desc limit:50
in:attributed_flows time:last_24h ip:198.51.100.10 sort:time:desc limit:50
in:attributed_flows time:last_24h service_name:serviceradar-web sort:time:desc limit:50
in:attributed_flows time:last_24h port:22 sort:time:desc limit:50
in:flows time:last_24h port:22 sort:time:desc limit:50
in:public_endpoints port:22 limit:50
in:attributed_flows time:last_1h stats:"count(*) as total by agent_id, attribution_status" sort:total:desc
in:addon_statuses addon_id:netprobe sort:reported_at:desc limit:50
```

**Bidirectional helpers (no cross-field `OR`):** use `ip:` for either endpoint
address and `port:` for either endpoint port. Do not write
`(dst_port:22 OR src_port:22)` — that is not valid SRQL. See the
[SRQL Cookbook](./srql-cookbook.md#attributed-flows-and-public-endpoints) and
[language reference](./srql-language-reference.md).

## Validation

On an agent host:

```bash
sudo systemctl status serviceradar-netprobe.service
sudo journalctl -u serviceradar-netprobe.service -n 100 --no-pager
sudo ss -plunt
readlink -f /var/lib/serviceradar/agent/addons/netprobe/current
readlink -f /proc/$(pidof serviceradar-netprobe)/exe
```

Confirm the metrics endpoint if enabled:

```bash
curl -s http://127.0.0.1:9417/metrics
```

Useful metric classes include:

- eBPF events received, dropped, and parse failures.
- Attribution cache hits, misses, stale entries, and eviction counts.
- Ring buffer queue lag and backpressure/drop counters.
- Raw observations emitted and duplicate observations suppressed.
- AF_XDP packet counts, drops, and unsupported-interface fallbacks.
- Cold-path metadata enrichment counts and failures.

In the ServiceRadar UI:

- **Settings > Agents > Add-ons** shows package approval and assignment state.
- The agent detail page shows installed, active, unhealthy, and drift state.
- **Observability > Attributed Flows** shows the joined flow/process view.
- NetFlow flow details show matching process attribution when a join exists.

## Troubleshooting

### Add-on is assigned but inactive

Check the agent detail page for add-on drift. Then inspect the host unit:

```bash
sudo systemctl status serviceradar-netprobe.service
sudo journalctl -u serviceradar-netprobe.service -n 200 --no-pager
```

Common causes are unsupported architecture, failed artifact verification, missing BPF
capabilities, an interface allowlist that does not match host interfaces, or a blocked
gateway connection.

If the assignment targets `k8s-agent`, move it to the worker-node agent. The
in-cluster Kubernetes agent intentionally skips host-level netprobe activation and
visibility bootstrap writes so pod filesystem constraints do not block normal config
updates.

### No attributed flows

Confirm:

- NetFlow data is arriving for the same time range.
- Host raw observations are arriving from the agent that owns one endpoint.
- The source/destination tuple and protocol are supported.
- Clock skew between the NetFlow exporter and agent host is within the join window.
- The attributed-flow retention/discard settings have not removed unmatched raw
  observations before delayed NetFlow batches arrive.
- `emit_raw_flow_attribution_events` is enabled when using central delayed joins.
- The add-on status row is fresh in `in:addon_statuses addon_id:netprobe`.

For protocol coverage, TCP and UDP attribution are expected first. ICMP requires
protocol-specific tuple extraction because there are no TCP/UDP ports to correlate.

### CPU is higher than expected

Use `pidstat`, service metrics, and queue/drop counters together:

```bash
sudo pidstat -p "$(pidof serviceradar-netprobe)" 1 30
curl -s http://127.0.0.1:9417/metrics | grep -E 'netprobe_.*(drop|lag|attribution|metadata)'
```

Sustained CPU usually comes from one of four places: packet rate, ring-buffer drain
pressure, attribution-cache churn, or cold-path metadata enrichment. The target
architecture is event-driven socket/process inventory with bounded queues and no
periodic hot-path procfs scans.

For release validation, capture both host CPU and pipeline health:

```bash
sudo pidstat -p "$(pidof serviceradar-netprobe)" 1 30
curl -s http://127.0.0.1:9417/metrics | grep -E 'netprobe_.*(drop|lag|cache|coalesce|raw)'
```

CPU below the fleet budget is not enough by itself. Also check that event drops are
not rising, queue lag is bounded, duplicate suppression is active, and attributed-flow
hit rate is not regressing.

### Read-only flow-attribution diagnostic sequence

Check the pipeline in order. A later stage cannot disprove a failure at an earlier
one, and a correlator log line is supporting evidence rather than the success gate.

1. On the agent host, record the running add-on version and start time, then verify
   that the bounded TCP stages advance after a controlled completed handshake:

   ```bash
   systemctl show serviceradar-netprobe -p ExecMainStartTimestamp -p MainPID
   curl -fsS http://127.0.0.1:9417/metrics | grep -E 'serviceradar_netprobe_attribution_(stage|records)_total'
   ```

   `program_attach` and `ring_reader` must be `ready`; a TCP record must reach
   `tuple_extraction=accepted` and `owner_resolution=hit`. An owner miss is counted
   but is not emitted as process attribution.

   Record the stimulus boundary and exact identity/tuple before querying CNPG. The
   examples below use `psql` variables so an unrelated row cannot make a check pass:

   ```sql
   \set stimulus_started_at '2026-09-03T12:00:00Z'
   \set partition 'default'
   \set agent_id 'agent-example'
   \set local_ip '192.0.2.10'
   \set local_port '45678'
   \set remote_ip '198.51.100.20'
   \set remote_port '20000'
   \set pid '1234'
   ```

2. In CNPG, require a fresh producer row. This query always returns a row, including
   an explicit zero count:

   ```sql
   SELECT count(*) AS fresh_tcp_attributions,
          max(observed_at) AS newest_observed_at
   FROM platform.flow_process_attribution_current
   WHERE proto = 6
     AND observed_at >= :'stimulus_started_at'::timestamptz
     AND partition = :'partition'
     AND agent_id = :'agent_id'
     AND local_ip = :'local_ip'
     AND local_port = :'local_port'::integer
     AND remote_ip = :'remote_ip'
     AND remote_port = :'remote_port'::integer
     AND pid = :'pid'::integer;
   ```

3. Only after step 2 is non-zero, verify that the production-sized, newest-first
   5,000-flow sample and the attribution window share an endpoint and tuple. Keep
   the partition predicate when investigating a specific tenant:

   ```sql
   WITH recent_flows AS (
     SELECT time, partition, protocol_num,
            src_endpoint_ip, src_endpoint_port,
            dst_endpoint_ip, dst_endpoint_port
     FROM platform.ocsf_network_activity
     WHERE time > now() - interval '15 minutes'
       AND (ocsf_payload ->> 'event_type') IS DISTINCT FROM 'attributed_flow'
     ORDER BY time DESC
     LIMIT 5000
   ),
   controlled_flows AS (
     SELECT *
     FROM recent_flows
     WHERE time >= :'stimulus_started_at'::timestamptz
       AND partition = :'partition'
       AND protocol_num = 6
       AND (
         (src_endpoint_ip, src_endpoint_port, dst_endpoint_ip, dst_endpoint_port) =
           (:'local_ip', :'local_port'::integer, :'remote_ip', :'remote_port'::integer)
         OR
         (src_endpoint_ip, src_endpoint_port, dst_endpoint_ip, dst_endpoint_port) =
           (:'remote_ip', :'remote_port'::integer, :'local_ip', :'local_port'::integer)
       )
   )
   SELECT count(*) AS exact_or_reverse_tcp_candidates
   FROM controlled_flows f
   JOIN platform.flow_process_attribution_current a
     ON a.partition = f.partition
    AND a.partition = :'partition'
    AND a.agent_id = :'agent_id'
    AND a.pid = :'pid'::integer
    AND a.proto = f.protocol_num
    AND a.observed_at >= :'stimulus_started_at'::timestamptz
    AND a.observed_at BETWEEN f.time - interval '900 seconds'
                          AND f.time + interval '900 seconds'
    AND (
      (a.local_ip, a.local_port, a.remote_ip, a.remote_port) =
        (f.src_endpoint_ip, f.src_endpoint_port,
         f.dst_endpoint_ip, f.dst_endpoint_port)
      OR
      (a.local_ip, a.local_port, a.remote_ip, a.remote_port) =
        (f.dst_endpoint_ip, f.dst_endpoint_port,
         f.src_endpoint_ip, f.src_endpoint_port)
    )
   WHERE f.protocol_num = 6;
   ```

   Zero here means there is no eligible exact tuple in the bounded production
   sample; inspect wildcard, relaxed UDP, node-SNAT, or public-endpoint topology as
   appropriate rather than blaming the producer.

4. Finally, gate success on the persisted OCSF artifact newer than the stimulus:

   ```sql
   SELECT count(*) AS attributed_tcp_flows,
          max(time) AS newest_attributed_flow
   FROM platform.ocsf_network_activity
   WHERE protocol_num = 6
     AND time >= :'stimulus_started_at'::timestamptz
     AND partition = :'partition'
     AND (ocsf_payload ->> 'agent_id') = :'agent_id'
     AND (ocsf_payload #>> '{attribution,pid}')::integer = :'pid'::integer
     AND (
       (src_endpoint_ip, src_endpoint_port, dst_endpoint_ip, dst_endpoint_port) =
         (:'local_ip', :'local_port'::integer, :'remote_ip', :'remote_port'::integer)
       OR
       (src_endpoint_ip, src_endpoint_port, dst_endpoint_ip, dst_endpoint_port) =
         (:'remote_ip', :'remote_port'::integer, :'local_ip', :'local_port'::integer)
     )
     AND (ocsf_payload ->> 'event_type') = 'attributed_flow';
   ```

   A stamped-count log without this row is not success. Re-run the final query after
   the correlator pass to catch partial or stale observations.

### Missing container or workload fields

`netprobe` can capture cgroup/container hints, but user-friendly pod, namespace,
container name, image, and cluster metadata come from the
[Workload Identity](./workload-identity.md) add-on. Verify that collector is active on
the same host and that upstream joins are receiving its metadata.

If a row has process attribution but no workload identity, check the container ID
first. A missing container ID usually means the process is host-level or cold metadata
enrichment has not found the cgroup yet. A present container ID with blank workload
fields usually points to Workload Identity collection or upstream join timing.

## Privacy and retention

`netprobe` does not store packet payloads by default. It emits metadata needed for
flow correlation, process attribution, passive evidence, and troubleshooting. Keep
retention short for high-volume raw observations, and use chart/control-plane knobs to
discard unmatched raw observations when a deployment does not need forensic history
for delayed joins.

For SaaS-scale deployments, treat raw attribution observations as hot operational
data. Retain them only as long as needed for delayed NetFlow joins and short
investigation windows, aggregate current attribution state for UI queries, and move
longer forensic history to cold storage rather than keeping every unmatched event in
CNPG indefinitely.
