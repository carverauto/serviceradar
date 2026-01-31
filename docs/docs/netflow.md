---
title: NetFlow Ingest Guide
---

# NetFlow Ingest Guide

ServiceRadar ingests flow telemetry to expose traffic matrices, top talkers, and application reachability trends. The NetFlow collector is a high-performance Rust daemon that receives NetFlow v5/v9/IPFIX exports from network devices and processes them through the ServiceRadar pipeline.

## Architecture Overview

```
Network Devices → NetFlow Collector → NATS JetStream → Zen Rules → db-event-writer → CNPG/TimescaleDB
   (v5/v9/IPFIX)    (Rust, UDP:2055)   (Message Broker)  (OCSF Transform)  (Persistence)     (Query via SRQL)
```

**Key Components:**
- **NetFlow Collector**: Rust daemon listening on UDP port 2055 (configurable)
- **AutoScopedParser**: RFC-compliant per-source template isolation (0.8.0+)
- **NATS JetStream**: Reliable message transport with at-least-once delivery
- **Zen Rules Engine**: Transforms raw flows to OCSF 1.7.0 schema
- **CNPG/TimescaleDB**: Time-series storage in `netflow_metrics` hypertable
- **SRQL**: Query flows via `in:flows` queries
- **Web UI**: NetFlow dashboard for top talkers and traffic analysis

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
cd cmd/netflow-collector
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
  "stream_name": "flows",
  "subject": "flows.raw.netflow",
  "partition": "default",
  "max_templates": 2000,
  "max_template_fields": 10000,
  "channel_size": 10000,
  "batch_size": 100,
  "publish_timeout_ms": 5000,
  "drop_policy": "drop_oldest",
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/certs",
    "tls": {
      "cert_file": "client.crt",
      "key_file": "client.key",
      "ca_file": "ca.crt"
    }
  },
  "metrics_addr": "0.0.0.0:50046"
}
```

**Key Parameters:**
- `listen_addr`: UDP socket binding (default: 0.0.0.0:2055)
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
- Capture application dictionaries (port → service mapping) in KV to improve SRQL readability.

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
nats stream info flows

# Should show:
# Messages: 125,432
# Subjects: 1 (flows.raw.netflow)
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

See [CHANGELOG.md](../../cmd/netflow-collector/CHANGELOG.md) for full details.

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
- [Device Config Quick Reference](../../cmd/netflow-collector/DEVICE-CONFIG.md)
- [TESTING.md](../../cmd/netflow-collector/TESTING.md) - Testing guide
