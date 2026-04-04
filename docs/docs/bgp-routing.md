---
title: BGP Routing Visibility
---

# BGP Routing Visibility

ServiceRadar provides comprehensive BGP routing visibility by extracting AS path and community information from NetFlow/IPFIX exports. This enables network operators to understand traffic routing decisions, identify transit patterns, and analyze AS-level traffic flows.

## Overview

BGP (Border Gateway Protocol) information is collected from network devices exporting NetFlow v9 or IPFIX with BGP-specific information elements. ServiceRadar processes these fields to provide:

- **AS Path Analysis**: Visualize the autonomous systems that traffic traverses
- **Community Tracking**: Monitor BGP communities for traffic engineering and policy enforcement
- **Topology Mapping**: Understand AS-level network topology and interconnections
- **Traffic Analytics**: Aggregate traffic statistics by AS number and routing policy

## Architecture

```
Network Devices     NetFlow Collector      NATS JetStream       EventWriter        Database
    (BGP-enabled    →  (Rust UDP:2055)  →  (flows.raw.netflow) → (Elixir)     →   (TimescaleDB)
     IPFIX exports)                                                                  ├─ ocsf_network_activity
                                                                                     └─ bgp_routing_info
```

The BGP data model is **protocol-agnostic**, allowing multiple collection sources:
- NetFlow v9 (Cisco, Juniper)
- IPFIX (RFC 7012)
- sFlow (future)
- Direct BGP peering/BMP (future)

## BGP Data Model

### AS Path

Ordered array of autonomous system numbers representing the routing path:

**Example**: `[64512, 64513, 15169]`
- Traffic originated from AS 64512
- Transited through AS 64513
- Reached destination AS 15169 (Google)

**Construction**:
1. Source AS (`bgpSourceAsNumber`, IPFIX IE 16)
2. Next-hop AS (`bgpNextAdjacentAsNumber`, IPFIX IE 128)
3. Destination AS (`bgpDestinationAsNumber`, IPFIX IE 17)

**Storage**: PostgreSQL `INTEGER[]` with GIN index for fast containment queries

### BGP Communities

32-bit values encoding routing policies (RFC 1997 format):

**Format**: `(AS_NUMBER << 16) | VALUE`

**Example**: `4259840100` = `0xFDE80064` = `65000:100`
- AS 65000 applied community value 100
- Typically used for traffic engineering, route filtering, or policy tagging

**Well-Known Communities**:
| Value | Name | Meaning |
|-------|------|---------|
| `0xFFFFFF01` | NO_EXPORT | Do not advertise to EBGP peers |
| `0xFFFFFF02` | NO_ADVERTISE | Do not advertise to any peer |
| `0xFFFFFF03` | NO_EXPORT_SUBCONFED | Do not advertise outside sub-confederation |
| `0xFFFFFF04` | NOPEER | Do not advertise to peers |

## Using the BGP Routing Dashboard

### Accessing the Dashboard

Navigate to: **Observability → BGP Routing**

Or directly: `http://your-serviceradar-instance/bgp-routing`

### Dashboard Features

#### 1. Traffic by AS Number
- Bar chart showing top ASes by traffic volume
- Click AS number to filter all views
- Click "View Flows →" to see NetFlow details

#### 2. Top BGP Communities
- Most common communities with traffic breakdown
- Displays both raw values and decoded AS:value format
- Links to NetFlow flows with specific communities

#### 3. AS Path Diversity
- Unique path count and statistics
- Average/maximum path length metrics
- Path length distribution

#### 4. AS Topology Graph
- Visual representation of AS-to-AS connections
- Edge thickness indicates traffic volume
- Interactive graph showing routing relationships

#### 5. AS Path Details Table
- All unique AS paths with traffic statistics
- Path visualization: `AS1 → AS2 → AS3`
- Sortable by traffic volume, packet count, or flow count

#### 6. Prefix Analysis
- Destination IP prefixes grouped by /24
- Shows which AS serves each prefix
- Traffic statistics per prefix

#### 7. Data Sources Panel
- Lists NetFlow exporters reporting BGP data
- Shows contribution by sampler
- Validates data collection pipeline

### Filtering and Time Ranges

**Time Range Selector**:
- Last 1 Hour (default)
- Last 6 Hours
- Last 24 Hours
- Last 7 Days

**Source Protocol Filter**:
- All Sources (NetFlow, sFlow, BGP Peering)
- NetFlow only
- sFlow only
- BGP Peering only

**AS and Community Filters**:
- Click any AS number to filter entire dashboard
- Click any community to filter by that community
- Filters are preserved in URL for bookmarking/sharing
- "Clear Filters" button to reset

### Exporting Data

Click **"Export CSV"** to download:
- Traffic by AS statistics
- AS path details
- Prefix analysis
- Formatted for spreadsheet analysis or reporting

## Querying BGP Data with SRQL

### Flow Queries

**Find flows traversing specific AS**:
```
in:flows as_path:[64512] time:last_1h
```

**Find flows with specific community**:
```
in:flows bgp_community:[65000:100] time:last_24h
```

**Combine filters**:
```
in:flows as_path:[64512] bgp_community:[NO_EXPORT] time:last_6h
```

**Array containment**:
```
in:flows as_path contains [64512, 64513] time:last_1h
```

### Analytics Queries

Query the `bgp_routing_info` table directly for custom analytics:

```sql
-- Top ASes by traffic
SELECT
  unnest(as_path) as as_number,
  SUM(total_bytes) as bytes
FROM platform.bgp_routing_info
WHERE timestamp >= NOW() - INTERVAL '1 hour'
GROUP BY as_number
ORDER BY bytes DESC
LIMIT 10;

-- Community usage
SELECT
  unnest(bgp_communities) as community,
  COUNT(*) as flow_count
FROM platform.bgp_routing_info
WHERE timestamp >= NOW() - INTERVAL '24 hours'
GROUP BY community
ORDER BY flow_count DESC;

-- AS path length distribution
SELECT
  array_length(as_path, 1) as path_length,
  COUNT(*) as count
FROM platform.bgp_routing_info
WHERE timestamp >= NOW() - INTERVAL '1 hour'
GROUP BY path_length
ORDER BY path_length;
```

## Configuring NetFlow Exporters

To collect BGP information, your network devices must export NetFlow/IPFIX with BGP information elements enabled.

### Cisco IOS/IOS-XE

```cisco
flow exporter SERVICERADAR
  destination <serviceradar-collector-ip>
  transport udp 2055

flow record BGP_ENABLED
  match ipv4 tos
  match ipv4 protocol
  match ipv4 source address
  match ipv4 destination address
  match transport source-port
  match transport destination-port
  match flow direction

  ! BGP fields
  match routing source as
  match routing destination as
  match routing next-hop address ipv4
  match bgp source community-list
  match bgp destination community-list

  collect counter bytes
  collect counter packets
  collect timestamp sys-uptime first
  collect timestamp sys-uptime last

flow monitor SERVICERADAR_MONITOR
  exporter SERVICERADAR
  record BGP_ENABLED
  cache timeout active 60

interface GigabitEthernet0/0
  ip flow monitor SERVICERADAR_MONITOR input
  ip flow monitor SERVICERADAR_MONITOR output
```

### Juniper Junos

```juniper
set services flow-monitoring version9 template BGP_TEMPLATE
set services flow-monitoring version9 template BGP_TEMPLATE flow-active-timeout 60
set services flow-monitoring version9 template BGP_TEMPLATE flow-inactive-timeout 30
set services flow-monitoring version9 template BGP_TEMPLATE template-refresh-rate packets 1000
set services flow-monitoring version9 template BGP_TEMPLATE option-refresh-rate packets 1000

set services flow-monitoring version9 template BGP_TEMPLATE ipv4-template
set services flow-monitoring version9 template BGP_TEMPLATE source-as
set services flow-monitoring version9 template BGP_TEMPLATE destination-as
set services flow-monitoring version9 template BGP_TEMPLATE peer-as
set services flow-monitoring version9 template BGP_TEMPLATE bgp-community

set forwarding-options sampling instance SERVICERADAR
set forwarding-options sampling instance SERVICERADAR input rate 100
set forwarding-options sampling instance SERVICERADAR family inet output flow-server <serviceradar-collector-ip> port 2055
set forwarding-options sampling instance SERVICERADAR family inet output flow-server <serviceradar-collector-ip> version9 template BGP_TEMPLATE

set interfaces ge-0/0/0 unit 0 family inet sampling input
set interfaces ge-0/0/0 unit 0 family inet sampling output
```

## Troubleshooting

### No BGP Data Visible

**Check NetFlow exports include BGP fields**:
```bash
# On ServiceRadar host, capture NetFlow packets
tcpdump -i any -n 'udp port 2055' -w /tmp/netflow.pcap

# Analyze with nfdump or similar tool to verify BGP IEs present
```

**Verify collector is processing BGP fields**:
```bash
# Check collector logs
docker logs serviceradar-netflow-collector 2>&1 | grep -i bgp

# Should see: "Parsed BGP fields: as_path=[...], communities=[...]"
```

**Check database has BGP data**:
```sql
SELECT COUNT(*)
FROM platform.bgp_routing_info
WHERE timestamp >= NOW() - INTERVAL '1 hour';

-- Should return > 0 if data is flowing
```

### Missing AS Organization Names

AS organization names are resolved via Team Cymru DNS whois service:

**Test DNS resolution**:
```bash
dig +short TXT AS15169.asn.cymru.com
# Should return: "15169 | US | arin | 2000-03-30 | GOOGLE, US"
```

**Check AS lookup cache**:
```elixir
# In Elixir console (iex -S mix)
ServiceRadar.BGP.ASLookup.lookup(15169)
# Should return: "Google LLC"
```

### Performance Issues

BGP queries use GIN indexes for fast array operations. If queries are slow:

**Check index usage**:
```sql
EXPLAIN ANALYZE
SELECT * FROM platform.bgp_routing_info
WHERE as_path @> ARRAY[64512]
  AND timestamp >= NOW() - INTERVAL '1 hour';

-- Should show "Index Scan using idx_bgp_routing_as_path"
```

**Vacuum and analyze**:
```sql
VACUUM ANALYZE platform.bgp_routing_info;
```

## Integration Examples

### Alert on Unexpected AS Path

Create a Zen rule to alert when traffic traverses unexpected ASes:

```yaml
name: "Unexpected Transit AS Detected"
stream: flows.raw.netflow
filter: |
  as_path contains [SUSPICIOUS_AS_NUMBER]
actions:
  - type: alert
    severity: warning
    message: "Traffic routing through unexpected AS: {{ as_path }}"
```

### Export to External SIEM

Query BGP data and forward to Splunk/Elastic:

```bash
# Hourly export of BGP topology
*/60 * * * * psql -h localhost -U postgres -d serviceradar -c \
  "COPY (SELECT * FROM platform.bgp_routing_info WHERE timestamp >= NOW() - INTERVAL '1 hour') TO STDOUT CSV HEADER" \
  | curl -X POST https://splunk.example.com/services/collector/event \
       -H "Authorization: Splunk YOUR-HEC-TOKEN" \
       --data-binary @-
```

### Grafana Dashboard

Query BGP metrics from Postgres datasource:

```sql
-- AS traffic over time
SELECT
  time_bucket('5 minutes', timestamp) as time,
  unnest(as_path) as as_number,
  SUM(total_bytes) as bytes
FROM platform.bgp_routing_info
WHERE timestamp >= NOW() - INTERVAL '$__interval'
GROUP BY time, as_number
ORDER BY time;
```

## API Reference

### Phoenix LiveView Events

**Filter by AS**:
```javascript
// Push event from JavaScript
this.pushEvent("filter_by_as", {as: 64512})
```

**Filter by Community**:
```javascript
this.pushEvent("filter_by_community", {community: 4259840100})
```

**Export CSV**:
```javascript
this.pushEvent("export_csv", {})
```

### Database Schema

**bgp_routing_info table**:
```sql
CREATE TABLE platform.bgp_routing_info (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  timestamp TIMESTAMPTZ NOT NULL,
  source_protocol TEXT NOT NULL,
  as_path INTEGER[] NOT NULL,
  bgp_communities INTEGER[],
  src_ip INET,
  dst_ip INET,
  total_bytes BIGINT DEFAULT 0,
  total_packets BIGINT DEFAULT 0,
  flow_count INTEGER DEFAULT 0,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- TimescaleDB hypertable
SELECT create_hypertable('platform.bgp_routing_info', 'timestamp');

-- GIN indexes for array queries
CREATE INDEX idx_bgp_routing_as_path ON platform.bgp_routing_info USING GIN (as_path);
CREATE INDEX idx_bgp_routing_communities ON platform.bgp_routing_info USING GIN (bgp_communities);
```

## Further Reading

- [NetFlow Ingest Guide](./netflow.md) - Complete NetFlow/IPFIX documentation
- [SRQL Language Reference](./srql-language-reference.md) - Query syntax and operators
- [RFC 7012](https://www.rfc-editor.org/rfc/rfc7012.html) - IPFIX Protocol Specification
- [RFC 1997](https://www.rfc-editor.org/rfc/rfc1997.html) - BGP Communities Attribute
- [Team Cymru IP to ASN](https://www.team-cymru.com/ip-asn-mapping) - AS number lookup service
