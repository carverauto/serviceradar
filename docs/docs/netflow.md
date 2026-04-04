---
title: NetFlow Ingest Guide
---

# NetFlow Ingest Guide

ServiceRadar ingests flow telemetry to expose traffic matrices, top talkers, and application reachability trends. The NetFlow collector is a high-performance Rust daemon that receives NetFlow v5/v9/IPFIX exports from network devices and processes them through the ServiceRadar pipeline.

## Architecture Overview

ServiceRadar uses a single canonical NetFlow ingest path:

```
Network Devices → NetFlow Collector → NATS → EventWriter → ocsf_network_activity
   (v5/v9/IPFIX)    (Rust, UDP:2055)          (protobuf decode)   (canonical flow store)
                                                └──────────────→ bgp_routing_info
                                                                   (derived BGP analytics)
```

**Key Components:**
- **NetFlow Collector**: Rust daemon listening on UDP port 2055 (configurable)
- **AutoScopedParser**: RFC-compliant per-source template isolation (0.8.0+)
- **NATS JetStream**: Reliable message transport carrying protobuf `FlowMessage` bytes on `flows.raw.netflow`
- **EventWriter**: Elixir/Broadway processor that decodes protobuf, persists OCSF flow rows, and derives BGP observations
- **CNPG/TimescaleDB**: Time-series storage with canonical `ocsf_network_activity` flow rows and derived `bgp_routing_info`
- **SRQL**: Query flows via `in:flows` from `ocsf_network_activity`
- **Web UI**: NetFlow dashboard with BGP topology visualization

## BGP Routing Support (NEW)

ServiceRadar now captures and visualizes BGP routing information from NetFlow/IPFIX exports, enabling deep insights into AS-level traffic patterns and routing decisions.

### BGP Fields

**AS Path** (`as_path` in `bgp_routing_info`):
- Ordered array of AS numbers in the routing path
- Format: `[SOURCE_AS, INTERMEDIATE_AS, ..., DEST_AS]`
- Example: `[64512, 64513, 64514]` indicates traffic traversed three autonomous systems
- Stored as PostgreSQL `INTEGER[]` in `bgp_routing_info` with GIN index for fast containment queries

**BGP Communities** (`bgp_communities` in `bgp_routing_info`):
- Array of 32-bit community values (RFC 1997 format)
- Format: High 16 bits = AS number, low 16 bits = value
- Example: `4259840100` = `0xFDE80064` = `65000:100`
- Enables policy-based routing and traffic engineering visibility
- Stored as PostgreSQL `INTEGER[]` in `bgp_routing_info` with GIN index

**Well-Known Communities**:
- `NO_EXPORT` (0xFFFFFF01): Do not advertise to EBGP peers
- `NO_ADVERTISE` (0xFFFFFF02): Do not advertise to any peer
- `NO_EXPORT_SUBCONFED` (0xFFFFFF03): Do not advertise outside sub-confederation
- `NOPEER` (0xFFFFFF04): Do not advertise to peers

### Querying BGP Data with SRQL

**Find flows traversing specific AS:**
```bash
srql "in:flows as_path:[64512] time:last_1h"
```

**Find flows with specific BGP community:**
```bash
srql "in:flows bgp_community:[65000:100] time:last_24h"
```

**Find flows with well-known community NO_EXPORT:**
```bash
srql "in:flows bgp_community:[NO_EXPORT] time:last_6h"
```

**Combine AS and community filters:**
```bash
srql "in:flows as_path:[64512] bgp_community:[65000:100] time:last_1h"
```

### BGP Visualization in UI

Navigate to **NetFlow → BGP Analysis** to view:

**1. AS Path Display**
- Visual representation: `AS64512 → AS64513 → AS64514`
- Hop count and path length metrics
- Identification of transit vs. direct peers

**2. Traffic by AS Statistics**
- Top 10 AS numbers by traffic volume
- Bar chart with bytes/packets/flow count per AS
- Drill-down to see all flows for a specific AS

**3. Top BGP Communities**
- Most common communities in your traffic
- Traffic volume per community
- Well-known community name mapping

**4. AS Path Diversity Metrics**
- Unique path count
- Average path length
- Maximum path length
- Path redundancy analysis

**5. AS Topology Graph** (Interactive SVG)
- Nodes: Autonomous systems sized by traffic volume
- Edges: AS connections sized by connection traffic
- Hover tooltips show AS number, bytes, flow count
- Click-to-filter applies `as_path:[X]` filter

### Database Queries

**Direct PostgreSQL queries for advanced analysis:**

**Find all flows traversing AS 64512:**
```sql
SELECT
  timestamp,
  src_ip,
  dst_ip,
  as_path,
  total_bytes,
  total_packets
FROM bgp_routing_info
WHERE as_path @> ARRAY[64512]
  AND timestamp > NOW() - INTERVAL '1 hour'
ORDER BY total_bytes DESC
LIMIT 20;
```

**Traffic aggregation by AS:**
```sql
SELECT
  unnest(as_path) AS asn,
  SUM(total_bytes) AS total_bytes,
  SUM(total_packets) AS total_packets,
  SUM(flow_count) AS flow_count
FROM bgp_routing_info
WHERE timestamp > NOW() - INTERVAL '1 hour'
  AND as_path IS NOT NULL
GROUP BY asn
ORDER BY total_bytes DESC
LIMIT 10;
```

**Find flows with specific BGP community:**
```sql
SELECT
  timestamp,
  src_ip,
  dst_ip,
  as_path,
  bgp_communities,
  total_bytes
FROM bgp_routing_info
WHERE bgp_communities @> ARRAY[4259840100]  -- 65000:100
  AND timestamp > NOW() - INTERVAL '1 hour'
ORDER BY timestamp DESC;
```

**AS path topology (edges between ASNs):**
```sql
WITH path_edges AS (
  SELECT
    as_path[i] as source_as,
    as_path[i+1] as dest_as,
    total_bytes,
    total_packets
  FROM bgp_routing_info,
       generate_series(1, array_length(as_path, 1) - 1) i
  WHERE timestamp > NOW() - INTERVAL '1 hour'
    AND as_path IS NOT NULL
    AND array_length(as_path, 1) > 1
)
SELECT
  source_as,
  dest_as,
  SUM(total_bytes) as total_bytes,
  SUM(total_packets) as total_packets,
  COUNT(*) as flow_count
FROM path_edges
GROUP BY source_as, dest_as
ORDER BY total_bytes DESC
LIMIT 20;
```

### GIN Index Performance

The `bgp_routing_info` table uses **GIN (Generalized Inverted Index)** indexes for fast array containment queries:

**Indexes:**
```sql
CREATE INDEX idx_bgp_routing_as_path
  ON bgp_routing_info USING GIN (as_path);

CREATE INDEX idx_bgp_routing_communities
  ON bgp_routing_info USING GIN (bgp_communities);
```

**Performance Characteristics:**
- Containment query (`@>` operator): O(log n) lookup
- Ideal for queries like: `WHERE as_path @> ARRAY[64512]`
- Index size: ~30% of table size
- Update performance: Slightly slower inserts due to index maintenance

**Query Planner Usage:**
```sql
EXPLAIN ANALYZE
SELECT COUNT(*) FROM bgp_routing_info
WHERE as_path @> ARRAY[64512];

-- Output shows:
-- Bitmap Index Scan on idx_bgp_routing_as_path
-- Index Cond: (as_path @> '{64512}'::integer[])
```

### Device Configuration for BGP Fields

**Cisco IOS-XE (IPFIX with BGP):**
```cisco
flow record SERVICERADAR-BGP-RECORD
  match ipv4 protocol
  match ipv4 source address
  match ipv4 destination address
  match transport source-port
  match transport destination-port
  collect counter bytes
  collect counter packets
  collect timestamp sys-uptime first
  collect timestamp sys-uptime last
  collect routing source as
  collect routing destination as
  collect routing next-hop as
  collect routing source as peer
  collect routing destination as peer
  collect bgp source-community-list
  collect bgp destination-community-list

flow monitor SERVICERADAR-BGP-MONITOR
  exporter SERVICERADAR-COLLECTOR
  cache timeout active 60
  cache timeout inactive 15
  record SERVICERADAR-BGP-RECORD
```

**Juniper (IPFIX with BGP):**
```juniper
set services flow-monitoring version-ipfix template SERVICERADAR-BGP
set services flow-monitoring version-ipfix template SERVICERADAR-BGP ipv4-template
set services flow-monitoring version-ipfix template SERVICERADAR-BGP flow-active-timeout 60
set services flow-monitoring version-ipfix template SERVICERADAR-BGP flow-inactive-timeout 15
set services flow-monitoring version-ipfix template SERVICERADAR-BGP source-address <ROUTER-IP>
set services flow-monitoring version-ipfix template SERVICERADAR-BGP nexthop-learning enable
set services flow-monitoring version-ipfix template SERVICERADAR-BGP autonomous-system-type origin
set services flow-monitoring version-ipfix template SERVICERADAR-BGP peer-as-fill-in-first-as

set forwarding-options sampling instance SERVICERADAR-BGP
set forwarding-options sampling instance SERVICERADAR-BGP family inet output flow-server <COLLECTOR-IP> port 2055
set forwarding-options sampling instance SERVICERADAR-BGP family inet output flow-server <COLLECTOR-IP> version-ipfix template SERVICERADAR-BGP
set forwarding-options sampling instance SERVICERADAR-BGP family inet output flow-server <COLLECTOR-IP> autonomous-system-type origin
```

**Important Notes:**
- BGP fields are only available in **IPFIX** exports
- NetFlow v5 and v9 have limited or no BGP support
- Router must have BGP configured to export BGP fields
- `bgp_communities` requires explicit configuration in flow record

### Type Conversion Notes (Developers)

**uint32 → int32 Conversion:**

IPFIX defines BGP fields as `unsigned32` (uint32), but PostgreSQL `INTEGER` type is signed (int32):
- **Max int32 value**: 2,147,483,647
- **Max uint32 value**: 4,294,967,295

**Handling:**
- Rust collector passes uint32 values as-is in protobuf
- Elixir EventWriter caps values at max int32: `min(value, 2_147_483_647)`
- In practice, AS numbers < 4,294,967,295 (32-bit ASNs)
- BGP communities typically < 2^31 for standard communities

**Why not BIGINT?**
- INTEGER[] arrays more efficient for GIN indexes
- AS numbers > 2^31 are extremely rare
- Extended communities use different format (not covered here)

## Collector Layout

### Components

- **Listener**: Receives UDP packets on port 2055 (default), parses NetFlow v5/v7/v9/IPFIX
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
  name: serviceradar-netflow-collector
spec:
  type: LoadBalancer
  ports:
    - port: 2055
      protocol: UDP
      name: netflow
```

**Docker Compose:**
```yaml
services:
  netflow-collector:
    image: ghcr.io/carverauto/serviceradar-netflow-collector:latest
    ports:
      - "2055:2055/udp"
      - "4739:4739/udp"  # IPFIX alternative port
    environment:
      - NATS_URL=nats://nats:4222
    networks:
      - serviceradar-net
```

**Standalone:**
```bash
cd rust/netflow-collector
cargo build --release
./target/release/serviceradar-netflow-collector --config netflow-collector.json
```

## Device Configuration

Network devices (routers, switches, firewalls) must be configured to export NetFlow data to the ServiceRadar collector.

### Configuration Requirements

1. **Destination IP**: ServiceRadar collector IP address
2. **Port**: 2055/udp (default, configurable)
3. **Protocol**: NetFlow v5, v9, or IPFIX (recommended)
4. **Timeouts**: Active 60s, Inactive 15s (recommended)
5. **Interfaces**: Which interfaces to monitor

### Cisco IOS/IOS-XE (NetFlow v9)

```cisco
! Configure flow exporter
flow exporter SERVICERADAR-COLLECTOR
  destination <COLLECTOR-IP>
  transport udp 2055
  source Loopback0
  template data timeout 60

! Configure flow record
flow record SERVICERADAR-RECORD
  match ipv4 protocol
  match ipv4 source address
  match ipv4 destination address
  match transport source-port
  match transport destination-port
  collect counter bytes
  collect counter packets
  collect timestamp sys-uptime first
  collect timestamp sys-uptime last

! Configure flow monitor
flow monitor SERVICERADAR-MONITOR
  exporter SERVICERADAR-COLLECTOR
  cache timeout active 60
  cache timeout inactive 15
  record SERVICERADAR-RECORD

! Apply to interfaces
interface GigabitEthernet0/0
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output

interface GigabitEthernet0/1
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output
```

### Cisco NXOS (NetFlow)

```cisco
feature netflow

flow exporter SERVICERADAR
  destination <COLLECTOR-IP> use-vrf management
  transport udp 2055
  source mgmt0
  version 9

flow record SERVICERADAR-RECORD
  match ipv4 source address
  match ipv4 destination address
  match ip protocol
  match transport source-port
  match transport destination-port
  collect counter bytes
  collect counter packets

flow monitor SERVICERADAR-MONITOR
  record SERVICERADAR-RECORD
  exporter SERVICERADAR

interface Ethernet1/1
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output
```

### Juniper (IPFIX)

```juniper
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE flow-active-timeout 60
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE flow-inactive-timeout 15
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE template-refresh-rate packets 30
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE template-refresh-rate seconds 60
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE ipv4-template

set forwarding-options sampling instance SERVICERADAR-INSTANCE
set forwarding-options sampling instance SERVICERADAR-INSTANCE family inet output flow-server <COLLECTOR-IP> port 2055
set forwarding-options sampling instance SERVICERADAR-INSTANCE family inet output flow-server <COLLECTOR-IP> version-ipfix template SERVICERADAR-TEMPLATE

set interfaces ge-0/0/0 unit 0 family inet sampling input
set interfaces ge-0/0/0 unit 0 family inet sampling output
```

### MikroTik RouterOS

```mikrotik
/ip traffic-flow
set enabled=yes
set interfaces=ether1,ether2
set cache-entries=16k
set active-flow-timeout=1m
set inactive-flow-timeout=15s

/ip traffic-flow target
add address=<COLLECTOR-IP>:2055 version=9
```

### Fortinet FortiGate

```fortinet
config system netflow
    set collector-ip <COLLECTOR-IP>
    set collector-port 2055
    set source-ip 0.0.0.0
    set active-flow-timeout 60
    set inactive-flow-timeout 15
end

config system interface
    edit "port1"
        set netflow-sampler both
    next
    edit "port2"
        set netflow-sampler both
    next
end
```

### Palo Alto Networks

```paloalto
set deviceconfig system netflow-collector <COLLECTOR-NAME> server <COLLECTOR-IP>
set deviceconfig system netflow-collector <COLLECTOR-NAME> port 2055
set deviceconfig system netflow-collector <COLLECTOR-NAME> transport udp

set network profiles netflow SERVICERADAR-PROFILE
set network profiles netflow SERVICERADAR-PROFILE server <COLLECTOR-NAME>
set network profiles netflow SERVICERADAR-PROFILE template-refresh-rate 60
set network profiles netflow SERVICERADAR-PROFILE active-timeout 60
set network profiles netflow SERVICERADAR-PROFILE inactive-timeout 15

set zone-protection-profile default-zone-protection netflow SERVICERADAR-PROFILE
```

### VyOS

```vyos
set system flow-accounting interface eth0
set system flow-accounting interface eth1
set system flow-accounting netflow server <COLLECTOR-IP> port 2055
set system flow-accounting netflow version 9
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-generic 15
```

## Multi-Source Deployments (0.8.0+)

ServiceRadar 0.8.0 introduces **AutoScopedParser**, which provides RFC-compliant template scoping for multi-source environments.

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

`/etc/serviceradar/netflow-collector.json`:

```json
{
  "listen_addr": "0.0.0.0:2055",
  "buffer_size": 65536,
  "nats_url": "nats://nats:4222",
  "stream_name": "events",
  "subject": "flows.raw.netflow",
  "stream_subjects": [
    "flows.raw.netflow"
  ],
  "partition": "default",
  "max_templates": 2000,
  "max_template_fields": 10000,
  "channel_size": 10000,
  "batch_size": 100,
  "publish_timeout_ms": 5000,
  "drop_policy": "drop_oldest",
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "tls": {
      "cert_file": "netflow-client.crt",
      "key_file": "netflow-client.key",
      "ca_file": "ca.crt"
    }
  },
  "metrics_addr": "0.0.0.0:50046"
}
```

**Key Parameters:**
- `listen_addr`: UDP socket binding (default: 0.0.0.0:2055)
- `stream_name`: JetStream stream for NetFlow subjects (default: events)
- `stream_subjects`: Stream subjects to ensure exist for canonical raw flow ingest
- `max_templates`: Template cache size per source (default: 2000)
- `max_template_fields`: Max fields per template for security (default: 10,000)
- `channel_size`: Bounded channel depth (default: 10,000)
- `batch_size`: Flows per NATS publish (default: 100)
- `drop_policy`: Backpressure handling (drop_oldest, drop_newest, block)

### Tuning for High Volume

**For 10,000+ flows/second:**

```json
{
  "buffer_size": 131072,
  "max_templates": 5000,
  "channel_size": 50000,
  "batch_size": 500,
  "publish_timeout_ms": 10000
}
```

**For multiple routers (10+ sources):**

```json
{
  "max_templates": 10000
}
```

## Registry and Metadata

- Use the embedded sync runtime (agent) to register flow exporters with site, account, and device tags.
- Populate interface maps in the registry so flows can be joined with SNMP interface stats.
- Capture application dictionaries (port to service mapping) in the control plane so SRQL and the UI can present friendly names.

## Verification

### 1. Check Collector is Running

```bash
# Docker
docker ps | grep netflow-collector
docker logs netflow-collector

# Kubernetes
kubectl get pods -l app=netflow-collector
kubectl logs -l app=netflow-collector --tail=100

# Standalone
ps aux | grep netflow-collector
journalctl -u netflow-collector -f
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
grep "Template learned" /var/log/netflow-collector.log

# Check cache stats
grep "Template Cache" /var/log/netflow-collector.log

# Look for errors
grep -i "error\|warn" /var/log/netflow-collector.log
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

Navigate to **http://localhost:3000/netflows** to view:
- Flow summary statistics
- Top talkers (source IPs)
- Top destinations
- Protocol distribution
- Bandwidth over time

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

**"Template collision"** (shouldn't happen with 0.8.0+)
- AutoScopedParser prevents this
- If seen, report as bug

### High CPU Usage

**Causes:**
- Very high flow rate (>50,000 flows/sec)
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

## Upgrade Notes

### Upgrading to 0.8.0

**Breaking Changes:**
- AutoScopedParser enabled by default (behavior change for multi-source)
- Template cache is now per-source (increases memory slightly)

**Benefits:**
- RFC-compliant template scoping
- Prevents template collisions
- Better observability with cache metrics
- Template event hooks for debugging

**Migration:**
- No configuration changes required
- Existing `max_templates` applies per-source
- Monitor logs for cache metrics to tune if needed

See `rust/netflow-collector/CHANGELOG.md` for full details.

## Performance Characteristics

**Tested Performance:**
- **Single source**: 50,000 flows/sec sustained on 4 CPU cores
- **Multi-source**: 20,000 flows/sec from 10 routers on 4 CPU cores
- **Memory**: ~500MB base + ~50MB per active source
- **Latency**: p95 < 10ms from UDP receipt to NATS publish

## Security Considerations

**Network Security:**
- Restrict UDP 2055 to known exporter IPs via firewall
- Use VPN or private network for exporter-to-collector communication
- Monitor for unusual sources in logs

**Template Validation (0.8.0+):**
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
- Device config quick reference: `rust/netflow-collector/DEVICE-CONFIG.md`
- Testing guide: `rust/netflow-collector/TESTING.md`
