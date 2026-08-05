---
title: NetFlow Ingest Guide
---

# NetFlow Ingest Guide

ServiceRadar ingests flow telemetry to expose traffic matrices, top talkers, and application reachability trends. The flow collector is a high-performance Rust daemon that receives NetFlow v5/v9/IPFIX and sFlow exports from network devices and processes them through the ServiceRadar pipeline.

For host process attribution on top of NetFlow, enable the
[Host Network Visibility](./netprobe.md) add-on on the relevant agent hosts. For pod,
namespace, container, and image enrichment, enable the separate
[Workload Identity](./workload-identity.md) add-on. The central pipeline joins these
streams and exposes the result through `in:attributed_flows`, flow details, and the
dashboard NetFlow map.

When investigating **public VIP or cloud LB destinations** (for example
`dst_ip` is a MetalLB or cloud load balancer address), the central correlator
joins [Kubernetes Public Endpoint Inventory](./k8s-public-endpoint-inventory.md)
with netprobe so **Attributed Flows** carry process *and* Service/Gateway owner
fields (`attribution.public_endpoint`). Inventory remains queryable via
`in:public_endpoints` and does not require host agents to hold Kubernetes API
credentials.

## Architecture Overview

ServiceRadar uses a single canonical NetFlow ingest path:

```
Network Devices → NetFlow Collector → NATS → EventWriter → ocsf_network_activity
   (v5/v9/IPFIX)    (Rust, UDP:2055)          (protobuf decode)   (canonical flow store)
                                                └──────────────→ bgp_routing_info
                                                                   (derived BGP analytics)
```

**Key Components:**
- **Flow Collector**: Rust daemon listening on UDP port 2055 for NetFlow (configurable) and UDP port 6343 for sFlow when enabled
- **AutoScopedParser**: RFC-compliant per-source template isolation
- **NATS JetStream**: Reliable message transport carrying protobuf `FlowMessage` bytes on `flows.raw.netflow`
- **EventWriter**: Elixir/Broadway processor that decodes protobuf, persists OCSF flow rows, and derives BGP observations
- **CNPG/TimescaleDB**: Time-series storage with canonical `ocsf_network_activity` flow rows and derived `bgp_routing_info`
- **SRQL**: Query flows via `in:flows` from `ocsf_network_activity`
- **Web UI**: NetFlow dashboard with BGP topology visualization

## BGP Routing Support

NetFlow v9 and IPFIX exports can carry BGP information elements (AS numbers, communities). ServiceRadar derives BGP analytics from these flows into the `bgp_routing_info` table. To keep this guide focused on the ingest path, all BGP field details, query examples, indexing, and device configuration for BGP elements live in [BGP Routing](./bgp-routing.md).

## Collector Layout

### Components

- **Listener**: Receives UDP packets on port 2055 (default), parses NetFlow v5/v9/IPFIX
- **Parser**: AutoScopedParser with per-source template caching (prevents collisions)
- **Publisher**: Batches flows and publishes to NATS JetStream (default: 100 flows/batch)
- **Metrics Reporter**: Logs template cache statistics every 30 seconds

### Deployment Options

**Kubernetes:**
```yaml
# Service definition exposes UDP 2055
apiVersion: v1
kind: Service
metadata:
  name: serviceradar-flow-collector
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  sessionAffinity: ClientIP
  ports:
    - port: 2055
      protocol: UDP
      name: netflow
    - port: 6343
      protocol: UDP
      name: sflow
```

Send NetFlow to `<FLOW_COLLECTOR_ADDRESS>:2055/UDP` and sFlow to `<FLOW_COLLECTOR_ADDRESS>:6343/UDP`. Keep the actual collector address in private operations material. Syslog can use a shared Gateway address instead; see [Kubernetes External Ingestion](./kubernetes-ingestion.md).

**Docker Compose:**
```yaml
services:
  flow-collector:
    image: registry.carverauto.dev/serviceradar/serviceradar-flow-collector:latest
    ports:
      - "2055:2055/udp"
      - "6343:6343/udp"
    environment:
      - NATS_URL=nats://nats:4222
    networks:
      - serviceradar-net
```

**Standalone:**
```bash
cd rust/flow-collector
cargo build --release
./target/release/serviceradar-flow-collector --config flow-collector.json
```

## Device Configuration

Network devices (routers, switches, firewalls) must be configured to export NetFlow data to the ServiceRadar collector.

### Configuration Requirements

1. **Destination IP**: ServiceRadar collector IP address
2. **Port**: 2055/udp (default, configurable)
3. **Protocol**: NetFlow v5, v9, or IPFIX (IPFIX recommended)
4. **Timeouts**: Active 60s, Inactive 15s (recommended)
5. **Interfaces**: Which interfaces to monitor

Per-vendor flow-export snippets (Cisco IOS-XE/NXOS, Juniper, MikroTik, Fortinet, Palo Alto, VyOS) are maintained in the device quick reference at `rust/flow-collector/DEVICE-CONFIG.md`. BGP-specific flow-record configuration is covered in [BGP Routing](./bgp-routing.md).

## Multi-Source Deployments

ServiceRadar's flow collector uses **AutoScopedParser**, which provides RFC-compliant template scoping for multi-source environments.

### Why AutoScopedParser Matters

**The Problem:**
- Router A sends template ID 256 with fields: [SRC_IP, DST_IP, BYTES]
- Router B sends template ID 256 with fields: [SRC_IP, DST_IP, PACKETS, PROTOCOL]
- Without scoping, Router B's template overwrites Router A's → data corruption

**The Solution:**
- AutoScopedParser isolates templates per source IP address
- RFC 3954 (NetFlow v9) and RFC 7011 (IPFIX) compliant
- Each source maintains independent template cache
- Template ID 256 from 192.168.1.1 is different from 256 from 192.168.1.2

### Template Cache Isolation

```
Source: 192.168.1.1:2055 (Router A)
  V9 Template Cache: 15 templates
  V9 Data Cache: 8 active flows

Source: 192.168.1.2:2055 (Router B)
  V9 Template Cache: 12 templates
  V9 Data Cache: 5 active flows

Source: 192.168.1.3:2055 (Firewall C)
  IPFIX Template Cache: 20 templates
  IPFIX Data Cache: 15 active flows
```

Each source has completely isolated caches, preventing template ID collisions.

## Monitoring and Observability

### Template Cache Metrics

The collector logs cache statistics **every 30 seconds**:

```
V9 Template Cache [192.168.1.1:2055] - Templates: 15/2000, Data: 8/2000,
  Template Hits/Misses: 1250/15, Data Hits/Misses: 8420/8

IPFIX Template Cache [192.168.1.2:2055] - Templates: 20/2000, Data: 12/2000,
  Template Hits/Misses: 3200/20, Data Hits/Misses: 12500/12
```

**Metrics:**
- **Size (current/max)**: Number of templates cached / maximum cache size
- **Hits**: Cache lookups that found the template (good)
- **Misses**: Cache lookups that didn't find template (requires fetch)
- **Evictions**: Templates removed due to cache size limits (logged separately)

**Healthy Cache:**
- Hit ratio > 95% (Hits / (Hits + Misses))
- Size well below max (< 50% utilization)
- Few or no evictions

**Unhealthy Cache:**
- High miss ratio (< 90%) → increase `max_templates`
- Size near max → increase `max_templates`
- Frequent evictions → increase `max_templates`
- Many "Missing template" warnings → network issues or router reboots

### Template Event Hooks

The collector logs important template lifecycle events:

```
[INFO] Template learned - ID: 256, Protocol: V9
[WARN] Template collision - ID: 256, Protocol: V9
[DEBUG] Template evicted - ID: 512, Protocol: V9
[DEBUG] Template expired - ID: 1024, Protocol: IPFIX
[WARN] Missing template - ID: 300, Protocol: V9. Flow data received before template definition.
```

**Event Types:**
- **Learned**: New template successfully cached
- **Collision**: Template ID reused with different definition (shouldn't happen with AutoScopedParser)
- **Evicted**: Template removed from cache due to size limits
- **Expired**: Template TTL expired
- **MissingTemplate**: Flow data arrived before template definition (normal during startup)

### Performance Metrics

Monitor these in logs and system metrics:

- **Flow ingestion rate**: Flows/second processed
- **Channel utilization**: Publisher channel usage (warn if >80%)
- **NATS publish latency**: Time to publish batches
- **Drop rate**: Flows dropped due to backpressure

## Configuration Reference

### Collector Configuration

The flow collector reads a single JSON file (`/etc/serviceradar/flow-collector.json`). Listener tuning fields (`buffer_size`, `max_templates`, `max_template_fields`, `pending_flows`) belong **inside each listener entry**, not at the top level.

```json
{
  "nats_url": "nats://nats:4222",
  "nats_creds_file": "/etc/serviceradar/creds/platform.creds",
  "stream_name": "events",
  "stream_subjects": ["flows.raw.netflow", "flows.raw.sflow"],
  "stream_max_bytes": 10737418240,
  "stream_replicas": 1,
  "partition": "default",
  "listeners": [
    {
      "protocol": "netflow",
      "listen_addr": "0.0.0.0:2055",
      "subject": "flows.raw.netflow",
      "buffer_size": 65536,
      "max_templates": 2000,
      "max_template_fields": 10000,
      "pending_flows": {
        "max_pending_flows": 256,
        "max_entries_per_template": 1024,
        "max_entry_size_bytes": 65535,
        "ttl_secs": 300
      }
    },
    {
      "protocol": "sflow",
      "listen_addr": "0.0.0.0:6343",
      "subject": "flows.raw.sflow",
      "buffer_size": 65536
    }
  ],
  "channel_size": 10000,
  "batch_size": 100,
  "publish_timeout_ms": 5000,
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "tls": {
      "cert_file": "flow-collector.pem",
      "key_file": "flow-collector-key.pem",
      "ca_file": "root.pem"
    }
  },
  "metrics_addr": "0.0.0.0:50046"
}
```

**Top-level parameters:**
- `nats_url`: NATS endpoint for JetStream publishing
- `nats_creds_file`: Optional path to NATS credentials file
- `stream_name`: JetStream stream for flow subjects (default: events)
- `stream_subjects`: Stream subjects to ensure exist for canonical raw flow ingest (each listener's `subject` is merged in automatically)
- `stream_max_bytes`: Stream size cap in bytes (default: 10 GiB)
- `stream_replicas`: JetStream replica count (default: 1, must be > 0)
- `partition`: Partition tag applied to ingested flows (default: `default`)
- `listeners`: One entry per UDP socket (`netflow` or `sflow`)
- `channel_size`: Bounded channel depth (default: 10,000)
- `batch_size`: Flows per NATS publish (default: 100)
- `publish_timeout_ms`: NATS publish timeout (default: 5,000)
- Backpressure is fixed to drop-newest: each listener owns a bounded mpsc channel of depth `channel_size`, and when it is full the listener drops the incoming datagram and increments a per-subject drop counter (no operator-tunable policy).
- `metrics_addr`: Optional address for the collector metrics endpoint

**Per-listener parameters:**
- `buffer_size`: UDP socket receive buffer (default: 65,536) — applies to both `netflow` and `sflow` listeners
- `max_templates` (netflow only): Template cache size per source (default: 2,000)
- `max_template_fields` (netflow only): Max fields per template for security (default: 10,000)
- `pending_flows` (netflow only): Optional cache for flow data that arrives before its template. Fields: `max_pending_flows` (1–10,000, default 256), `max_entries_per_template` (1–100,000, default 1,024), `max_entry_size_bytes` (1–1,048,576, default 65,535), `ttl_secs` (1–3,600, default 300)
- `max_samples_per_datagram` (sflow only): Optional cap on samples parsed per datagram

### Tuning for High Volume

For high flow rates, raise the per-netflow-listener cache sizes and the top-level channel/batch settings. The listener tuning fields stay inside the netflow listener entry:

```json
{
  "channel_size": 50000,
  "batch_size": 500,
  "publish_timeout_ms": 10000,
  "listeners": [
    {
      "protocol": "netflow",
      "listen_addr": "0.0.0.0:2055",
      "subject": "flows.raw.netflow",
      "buffer_size": 131072,
      "max_templates": 5000
    }
  ]
}
```

For deployments with many routers, increase `max_templates` on the netflow listener so each source has enough template cache headroom.

## Registry and Metadata

- Use the embedded sync runtime (agent) to register flow exporters with site, account, and device tags.
- Populate interface maps in the registry so flows can be joined with SNMP interface stats.
- Capture application dictionaries (port to service mapping) in the control plane so SRQL and the UI can present friendly names.

## Verification

### 1. Check Collector is Running

```bash
# Docker
docker ps | grep flow-collector
docker logs serviceradar-flow-collector-mtls

# Kubernetes
kubectl get pods -l app=serviceradar-flow-collector
kubectl logs -l app=serviceradar-flow-collector --tail=100

# Standalone
ps aux | grep flow-collector
journalctl -u flow-collector -f
```

### 2. Verify Packets Arriving

```bash
# Capture on collector host
sudo tcpdump -i any -n port 2055

# Should see:
# 15:30:45.123456 IP 192.168.1.1.12345 > 10.0.0.50.2055: UDP, length 1480
# 15:30:46.234567 IP 192.168.1.2.54321 > 10.0.0.50.2055: UDP, length 1200
```

### 3. Check Collector Logs

```bash
# Look for template learning
grep "Template learned" /var/log/flow-collector.log

# Check cache stats
grep "Template Cache" /var/log/flow-collector.log

# Look for errors
grep -i "error\|warn" /var/log/flow-collector.log
```

### 4. Query NATS Stream

```bash
# Check stream has messages
nats stream info events

# Should show flows.raw.netflow in the subjects list.
#
# Note: If an old `flows` stream already owns flows.raw.netflow, delete it so the
# `events` stream can claim the subject:
# nats stream rm flows
```

### 5. Query Database

```sql
-- Check recent flows
SELECT
  time,
  src_endpoint_ip,
  dst_endpoint_ip,
  dst_endpoint_port,
  protocol_name,
  bytes_total,
  packets_total
FROM ocsf_network_activity
WHERE time > NOW() - INTERVAL '5 minutes'
ORDER BY time DESC
LIMIT 20;

-- Count flows per source
SELECT
  src_endpoint_ip,
  COUNT(*) as flow_count,
  SUM(bytes_total) as total_bytes
FROM ocsf_network_activity
WHERE time > NOW() - INTERVAL '1 hour'
GROUP BY src_endpoint_ip
ORDER BY total_bytes DESC
LIMIT 10;
```

### 6. Query via SRQL

```bash
# Top talkers last hour
srql "in:flows time:last_1h groupby:src_endpoint_ip limit:10"

# Specific destination
srql "in:flows dst_endpoint_ip:8.8.8.8 time:last_24h"

# High bandwidth flows
srql "in:flows bytes_total:>10000000 time:last_1h"
```

### 7. Check Web UI

Navigate to **http://localhost/netflows** to view:
- Flow summary statistics
- Top talkers (source IPs)
- Top destinations
- Protocol distribution
- Bandwidth over time
- Prefix tag chips and filters (when [prefix-tag enrichment](./prefix-tags.md) is enabled)

## Common Issues

### No Flows Appearing

**Check:**
1. Device is configured and exporting (check device logs)
2. Network path allows UDP 2055 (firewall rules)
3. Collector is listening: `netstat -ulnp | grep 2055`
4. Packets arriving: `tcpdump -i any port 2055`
5. Collector logs show "Received X bytes from..."

### Template Warnings

**"Missing template - ID: 256"**
- **Normal during startup**: Router sends data before template
- **Wait 60 seconds**: Router will re-send template (per timeout)
- **Persistent**: Router may have lost template, reboot router or wait for TTL

**"Template collision"** (should not happen)
- AutoScopedParser prevents this
- If seen, report as bug

### High CPU Usage

**Causes:**
- Very high flow rate
- Complex templates with many fields
- Insufficient batching

**Solutions:**
- Increase `batch_size` to 500-1000
- Enable sampling on routers (1:100 or 1:1000)
- Scale horizontally (multiple collectors)

### Dropped Flows

**Log message:** "Publisher channel full, dropping flow message"

**Causes:**
- NATS JetStream slow or unavailable
- Channel too small for burst traffic
- Batch publish taking too long

**Solutions:**
- Increase `channel_size` to 50,000+
- Check NATS JetStream health
- Increase `batch_size` for better throughput
- Check network latency to NATS

## Performance Characteristics

The Rust flow collector is designed for high-throughput ingest with bounded memory. Actual sustainable rate depends on CPU allocation, template complexity, batch settings, and NATS/JetStream performance, so benchmark in your own environment rather than relying on fixed numbers. As general guidance:

- Throughput scales with CPU cores and `batch_size`; enable router-side sampling for very high flow rates.
- Memory stays bounded by `channel_size`, the per-listener template caches, and the optional `pending_flows` cache.
- End-to-end latency from UDP receipt to NATS publish is dominated by batching (`batch_size`) and `publish_timeout_ms`.

## Security Considerations

**Network Security:**
- Restrict UDP 2055 to known exporter IPs via firewall
- Use VPN or private network for exporter-to-collector communication
- Monitor for unusual sources in logs

**Template Validation:**
- Max template fields enforced (default: 10,000)
- Prevents memory exhaustion attacks
- Malformed templates rejected

**mTLS Support:**
- NATS connection can use mTLS
- Authenticates collector to NATS
- Encrypts flow data in transit

## Further Reading

- [NetFlow v9 RFC 3954](https://datatracker.ietf.org/doc/html/rfc3954)
- [IPFIX RFC 7011](https://datatracker.ietf.org/doc/html/rfc7011)
- [OCSF 1.7.0 Network Activity](https://schema.ocsf.io/1.7.0/classes/network_activity)
- [Troubleshooting Guide](./troubleshooting-guide.md#netflow)
- Device config quick reference: `rust/flow-collector/DEVICE-CONFIG.md`
- Testing guide: `rust/flow-collector/TESTING.md`
