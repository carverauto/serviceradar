# ADR: ServiceRadar Hybrid Data Organization and Relationship Modeling for Advanced Correlation

| Metadata | Value |
|----------|-------|
| Date     | 2025-05-15 |
| Author   | @mfreeman, @xAI, Gemini AI |
| Status   | Proposed |
| Tags     | serviceradar, relationships, graphdb, arangodb, proton, netflow, snmp, device-management, correlation, streaming-analytics |

| Revision | Date       | Author      | Info           |
|----------|------------|-------------|----------------|
| 1        | 2025-05-15 | @mfreeman   | Initial combined design |

## Context and Problem Statement

ServiceRadar currently collects diverse raw data from edge services (e.g., sweep, ICMP, SNMP, NetFlow) via agents and pollers, storing it in Timeplus Proton streams. A materialized view derives a unified `devices` stream, enabling a centralized inventory with `agent_id` and `poller_id` traceability. However, the system lacks a sophisticated mechanism to:

1. **Express Rich Relationships**: Define and query complex relationships *between devices* (e.g., topological connections like leaf-spine links, L2/L3 adjacencies) and *between devices and their components/data* (e.g., specific interfaces, NetFlow records originating from a device, SNMP metrics for an interface).

2. **Enable Advanced Data Correlation**: Perform analytics that require joining or relating disparate datasets, particularly NetFlow traffic data with SNMP interface/device performance metrics, to gain deeper operational insights.

3. **Support Topology-Aware Monitoring**: Model network topologies and track ECMP paths, backbone links, or transit connections, as outlined in PRD-02.

The current flat streaming model, while excellent for real-time data ingestion and basic analytics, does not adequately support these graph-like queries and complex correlations. Integrating a graph database like ArangoDB can address these needs by explicitly modeling entities and their relationships, while Proton continues to serve as the high-throughput streaming and real-time analytics engine.

## Prior Work and References

- **PRD-02: Topology-Aware Monitoring**:
    - Proposes dynamic topology discovery using LLDP/SNMP and flow-based analysis for ECMP and transit monitoring.
    - Suggests modeling CLOS fabrics and correlating metrics with topology elements.

- **PRD-03: Real-Time Monitoring with Proton**:
    - Describes SRQL enhancements for streaming queries and integration of gNMI, NetFlow, syslog, SNMP traps, and BGP.
    - Mentions ClickHouse for historical storage and potential ArangoDB use for SRQL translation.

- **PRD-04: Device Management System**:
    - Details the `devices` stream derived from raw data via a materialized view, with `IP`, `agent_id`, and `poller_id` as a composite key.
    - Emphasizes lightweight agents and no local caching.

- **PRD-05: Agent Device Caching & Reporting**:
    - Outlines agent data collection without local caching.
    - Defines `agent_id` propagation via `context.Context`.

- **PRD-01: NetFlow Integration**:
    - Outlines NetFlow collection, storage in ClickHouse (real-time) and Parquet/Iceberg (historical), and unified API access.
    - Suggests correlation between NetFlow and other data sources.

- **Existing Codebase** (`pkg/db/db.go`, `pkg/core/server.go`):
    - Defines Proton streams for raw data.
    - Implements gRPC-based data flow from agents to core, with `agent_id` and `poller_id` propagation.
    - Supports materialized views for deriving `devices` from raw streams.

## Design

We propose a hybrid architecture that leverages Timeplus Proton for real-time data ingestion and stream processing, and ArangoDB for graph-based relationship modeling, device mastering, and complex correlation queries. This approach maintains the existing one-way data flow (edge → poller → core) and minimizes agent complexity.

### 1. Data Organization

#### Timeplus Proton Streams (Real-time Data & Source of Truth for Events)

Proton will continue to be the primary ingestion point for all raw time-series and event data.

**Existing Streams (Enhanced):**

- **`sweep_results`, `icmp_results`, `snmp_results`:**
    - Fields: `ip`, `mac`, `hostname`, `agent_id`, `poller_id`, `timestamp`, `available`, `open_ports`, `metadata` (add `neighbor_ip`, `interface_id`).

- **`netflow_metrics`:**
    - Fields: `SrcAddr`, `DstAddr`, `SamplerAddress`, `SrcPort`, `DstPort`, `Protocol`, `Bytes`, `Packets`, `input_snmp`, `output_snmp`, `metadata`.

- **`timeseries_metrics`:**
    - Fields: `poller_id`, `metric_name`, `value`, `timestamp`, `metadata` (`target_device_ip`, `ifIndex`, `ifName`).

- **`devices`:**
    - Fields: `device_id`, `agent_id`, `poller_id`, `ip`, `mac`, `hostname`, `first_seen`, `last_seen`, `is_available`, `open_ports`, `interfaces`, `metadata`.

**New Streams:**

- **`discovered_interfaces` (Regular Stream for History):**
```sql
CREATE STREAM IF NOT EXISTS discovered_interfaces (
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id String,
    poller_id String,
    device_ip String,
    device_id String,
    ifIndex Int32,
    ifName Nullable(String),
    ifDescr Nullable(String),
    ifAlias Nullable(String),
    ifSpeed UInt64,
    ifPhysAddress Nullable(String),
    ip_addresses Array(String),
    ifAdminStatus Int32,
    ifOperStatus Int32,
    metadata Map(String, String)
)
PRIMARY KEY (device_id, ifIndex)
SETTINGS mode='versioned_kv', version_column='_tp_time';
```

- **`topology_discovery_events` (New Stream):**
    - Captures LLDP/CDP/BGP neighbor data to feed ArangoDB topology edges.

#### ArangoDB Collections (Graph Model & Device/Interface Master)

ArangoDB will be the primary master for detailed device attributes, interface inventories, and their relationships.

**Vertex Collections:**

- **`Devices`:**
    - `_key`: `device_id` (e.g., `ip:agent_id:poller_id`).
    - Attributes: `ip`, `all_ips` (array), `agent_id`, `poller_id`, `hostname`, `mac`, `first_seen`, `last_seen`, `is_available`, `vendor`, `model`, `role`, `open_ports`, `metadata`.

- **`Interfaces`:**
    - `_key`: `device_id:ifIndex`.
    - Attributes: `device_id`, `ifIndex`, `ifName`, `ifDescr`, `ifAlias`, `ifSpeed`, `ifPhysAddress`, `ip_addresses` (array), `ifAdminStatus`, `ifOperStatus`, `metadata`.

- **`Collections`:**
    - `_key`: `collection_type:unique_id`.
    - Attributes: `type`, `source_ip`, `timestamp`, `data`, `metadata`.

**Edge Collections:**

- **`DeviceHasInterface`:**
    - `_from`: `Devices/_key`
    - `_to`: `Interfaces/_key`

- **`DeviceToCollection`:**
    - `_from`: `Devices/_key`
    - `_to`: `Collections/_key`
    - Attributes: `collection_type`

- **`InterfaceToCollection`:**
    - `_from`: `Interfaces/_key`
    - `_to`: `Collections/_key`
    - Attributes: `collection_type`

- **`DeviceToDevice`:**
    - `_from`: `Devices/_key`
    - `_to`: `Devices/_key`
    - Attributes: `link_type`, `interface_from`, `interface_to`, `metadata`

### 2. Relationship Modeling

- **Device-Interface Ownership:**
    - Explicitly modeled via `DeviceHasInterface` edges in ArangoDB.
    - Sourced from the `discovered_interfaces` Proton stream.

- **Network Topology:**
    - Device-to-device connections modeled via `DeviceToDevice` edges.
    - Discovered via LLDP/CDP (from SNMP queries) and BGP neighbor information.
    - Populates the edges with metadata about connected interfaces.
    - Raw data first lands in `topology_discovery_events` Proton stream.

- **Data Collection Relationships:**
    - `DeviceToCollection` edges link devices to their associated data collections.
    - `InterfaceToCollection` edges link interfaces to metrics for that specific interface.
    - Enables correlation between devices/interfaces and their data points.

### 3. Data Flow and Synchronization

1. **Edge Services:**
    - Sweep: Add `open_ports`, `neighbor_ip` to `sweep_results`.
    - SNMP: Populate `discovered_interfaces` and `timeseries_metrics` with `ifIndex`, `target_device_ip`.
    - NetFlow: Include `SamplerAddress`, `input_snmp`, `output_snmp` in `netflow_metrics`.

2. **Agent:**
    - Forward raw data with `agent_id`.
    - No local caching or preprocessing required.

3. **Poller:**
    - Receives data from Agents.
    - Adds `poller_id`.
    - Forwards to Core with specific payloads sent to dedicated streams.

4. **Core Service & Proton:**
    - Receives data and writes to respective Proton streams.
    - `devices_mv` updates the `devices` stream.

5. **ArangoDB Sync Service (New):**
    - Subscribes to relevant Proton streams:
        - `devices`: Creates/updates `Devices` vertices.
        - `discovered_interfaces`: Creates/updates `Interfaces` vertices and `DeviceHasInterface` edges.
        - `topology_discovery_events`: Creates/updates `DeviceToDevice` edges.
    - Handles idempotency for vertices and edges.
    - Uses ArangoDB Go driver.

### 4. Data Correlation Logic

**NetFlow + SNMP Interface Correlation Workflow:**

1. **Start with a NetFlow Record:**
    - Identify `flow_timestamp`, `SamplerAddress` (NetFlow exporter IP), `input_snmp` (ingress ifIndex), `output_snmp` (egress ifIndex).

2. **Identify Device in ArangoDB:**
   ```sql
   FOR d IN Devices
       FILTER d.ip == @SamplerAddress OR @SamplerAddress IN d.all_ips
       LIMIT 1
       RETURN d
   ```

3. **Identify Interfaces in ArangoDB:**
   ```sql
   FOR i IN Interfaces
       FILTER i.device_id == d._key AND i.ifIndex IN [@input_snmp, @output_snmp]
       RETURN { device: d, interface: i }
   ```

4. **Fetch Relevant SNMP Metrics from Proton:**
   ```sql
   SELECT timestamp, metric_name, value
   FROM timeseries_metrics
   WHERE metadata['target_device_ip'] = @SamplerAddress
       AND metadata['ifIndex'] IN [@input_snmp, @output_snmp]
       AND timestamp BETWEEN @flow_timestamp - INTERVAL '5 minutes' AND @flow_timestamp + INTERVAL '5 minutes'
   ORDER BY timestamp
   ```

### 5. SRQL Enhancements

SRQL will be the primary way users interact with this correlated data.

- **Contextual Queries:**
  ```
  SHOW INTERFACES FOR DEVICE @device_identifier
  SHOW DEVICE WHERE IP = '...' WITH INTERFACES
  ```

- **Correlation Queries:**
  ```
  SHOW NETFLOW FOR DEVICE @device_identifier INTERFACE @interface_identifier 
  CORRELATED WITH SNMP_METRICS BETWEEN @start AND @end
  ```

- **Topology Queries:**
  ```
  SHOW NEIGHBORS FOR DEVICE @device_identifier INTERFACE @interface_identifier
  SHOW PATH FROM DEVICE @src_device INTERFACE @src_if TO DEVICE @dst_device INTERFACE @dst_if
  ```

- **JOIN and PATH Clauses:**
  ```sql
  STREAM devices JOIN netflow ON devices.ip = netflow.src_ip
  WHERE netflow.timestamp >= now() - INTERVAL '1 hour'
  PATH devices TO devices WHERE link_type = 'lldp'
  GROUP BY devices.ip
  HAVING sum(netflow.bytes) > 1000000
  ```

### 6. API and UI Enhancements

- **API Endpoints:**
    - `/api/topology/devices`: List devices with interfaces.
    - `/api/topology/links`: Retrieve topology links.
    - `/api/topology/paths?source={device_id}&target={device_id}`: Find paths between devices.
    - `/api/correlations`: Correlated NetFlow-SNMP data.

- **UI:**
    - Topology map using vis.js.
    - Correlation dashboards showing NetFlow traffic with SNMP metrics.
    - Path analysis visualizations.

### 7. Configuration

**ArangoDB Sync Service** (`/etc/serviceradar/arangodb-sync.json`):
```json
{
  "arangodb_url": "http://localhost:8529",
  "arangodb_db": "serviceradar",
  "arangodb_user": "serviceradar",
  "arangodb_password": "<secret>",
  "proton_streams": [
    "devices",
    "discovered_interfaces",
    "topology_discovery_events"
  ],
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "tls": {
      "cert_file": "arangodb.pem",
      "key_file": "arangodb-key.pem",
      "ca_file": "root.pem"
    }
  }
}
```

**Core Service** (`/etc/serviceradar/core.json`):
```json
{
  "topology": {
    "enabled": true,
    "arangodb_url": "http://localhost:8529",
    "arangodb_db": "serviceradar"
  }
}
```

## Decision

1. **Adopt Hybrid Proton & ArangoDB Architecture:**
    - Proton for all real-time event/metric ingestion, basic device status (`devices` stream), and historical interface discovery data (`discovered_interfaces` regular stream).
    - ArangoDB as the primary master for detailed device and interface attributes, and for modeling explicit relationships (device-interface, interface-interface topology).

2. **Implement New Proton Streams:**
    - `discovered_interfaces`: Regular append stream for historical interface state tracking.
    - `topology_discovery_events`: For LLDP/CDP/BGP neighbor data, feeding ArangoDB topology edges.

3. **Enrich Metric Metadata:**
    - Mandate `target_device_ip` and `ifIndex` in metadata for SNMP interface metrics.

4. **Create ArangoDB Sync Service:**
    - Develop `serviceradar-arangodb-sync` to populate ArangoDB from Proton streams.

5. **Extend SRQL for Correlation:**
    - Make SRQL the primary interface for complex correlation and topology queries.
    - Add support for contextual, correlation, and topology queries.

6. **Implement Phased Approach:**
    - Start with data enrichment, then Proton stream enhancements, followed by ArangoDB integration, and finally SRQL/API extensions.

## Consequences

### Positive
- **Rich Relationship Modeling:** ArangoDB provides a flexible, scalable way to model device and data relationships.
- **Historical Interface Tracking:** `discovered_interfaces` stream enables auditing interface changes over time.
- **Powerful Correlation:** Enables deep insights by joining NetFlow, SNMP, and topology data.
- **Scalability:** Proton handles high-volume streaming data while ArangoDB manages complex relationships.
- **Minimal Agent Impact:** No changes to the agent's lightweight design beyond `agent_id` propagation.
- **Extensibility:** Graph model supports future data sources and relationship types.

### Negative
- **Increased System Complexity:** Adds ArangoDB and sync service to the architecture.
- **Synchronization Overhead:** Real-time sync between Proton and ArangoDB may introduce latency.
- **Learning Curve:** AQL and graph queries require developer training.
- **Storage Overhead:** Some data duplication between Proton and ArangoDB.

### Neutral
- **Optional ArangoDB:** Users not requiring topology or correlation can disable ArangoDB.
- **Future-Proofing:** Architecture supports evolving needs (e.g., wasmCloud integration).
- **Hybrid Querying:** Some queries may require both Proton and ArangoDB, adding complexity but enabling powerful correlations.

## Implementation Plan

### Phase 1: Data Foundation (4 weeks)
- Define and implement schema for `discovered_interfaces` and `topology_discovery_events` streams in Proton.
- Modify SNMP checkers/pollers to populate these new streams.
- Enforce metadata enrichment (`target_device_ip`, `ifIndex`) in `timeseries_metrics` for SNMP interface metrics.
- Update `devices_mv` materialized view to include relationship metadata.
- Test data flow into these Proton streams.

### Phase 2: ArangoDB Integration (3 weeks)
- Set up ArangoDB instance(s) with appropriate security.
- Define schemas for `Devices`, `Interfaces`, `DeviceHasInterface`, and `InterfaceConnectsToInterface`.
- Develop and deploy the `serviceradar-arangodb-sync` service:
    - First: Sync `devices` (Proton) → `Devices` (ArangoDB).
    - Next: Sync `discovered_interfaces` (Proton) → `Interfaces` & `DeviceHasInterface` (ArangoDB).
    - Then: Sync `topology_discovery_events` (Proton) → `InterfaceConnectsToInterface` (ArangoDB).
- Test synchronization between Proton and ArangoDB.

### Phase 3: Correlation API and SRQL v1 (3 weeks)
- Develop API endpoints for retrieving device details with interfaces from ArangoDB.
- Implement initial SRQL support for querying devices and interfaces.
- Build backend logic for NetFlow-SNMP correlation.
- Expose this via new API endpoints and basic SRQL syntax.
- Test correlation queries with sample data.

### Phase 4: Advanced SRQL and UI (2 weeks)
- Extend SRQL for topology queries and advanced correlations.
- Develop API endpoints for topology visualization.
- Build UI components using vis.js for topology maps.
- Implement dashboards for correlated NetFlow-SNMP data.
- Test end-to-end functionality from SRQL to UI.

### Phase 5: Optimization and Hardening (2 weeks)
- Performance testing with 10,000+ devices and relationships.
- Optimize ArangoDB sync service for consistency and performance.
- Optimize ArangoDB queries with appropriate indexes.
- Optimize Proton streams and query performance.
- Security review and hardening.
- Documentation updates.

**Total Duration:** ~14 weeks

## Testing Approach

- **Unit Tests:**
    - ArangoDB sync service components.
    - SRQL parser extensions for correlation and topology queries.
    - API endpoints for topology and correlation data.

- **Integration Tests:**
    - Proton to ArangoDB synchronization.
    - NetFlow-SNMP correlation logic.
    - Topology discovery and visualization.

- **System Tests:**
    - End-to-end workflow with sample network topologies.
    - Performance with large device counts (10,000+).
    - Query response times for different correlation scenarios.

- **Usability Tests:**
    - SRQL syntax for correlation and topology queries.
    - UI components for topology visualization.
    - Dashboard usability for correlated data.

## Security Considerations

- **ArangoDB Security:**
    - Use mTLS for all ArangoDB connections.
    - Implement RBAC for ArangoDB access.
    - Encrypt sensitive data at rest.

- **API Security:**
    - Restrict access to topology and correlation endpoints based on user roles.
    - Implement rate limiting for complex queries.

- **Data Privacy:**
    - Consider anonymization options for sensitive network data.
    - Implement data retention policies.

- **Audit Logging:**
    - Log all synchronization activities.
    - Track correlation query usage.

## Documentation Requirements

- Update `docs/docs/architecture.md` with hybrid Proton-ArangoDB model.
- Add `docs/docs/topology.md` for topology-aware monitoring details.
- Add `docs/docs/correlation.md` for NetFlow-SNMP correlation examples.
- Update `docs/docs/srql.md` with new syntax for correlation and topology queries.
- Add deployment guides for ArangoDB and sync service.
- Provide configuration examples for different use cases.

## Alternatives Considered

### 1. Proton-Only with Enhanced Materialized Views
- **Pros**:
    - Simplifies architecture by using only one database system.
    - Leverages existing Proton expertise and infrastructure.
    - Potentially lower operational overhead.
- **Cons**:
    - Limited support for complex graph traversals and relationship queries.
    - Materialized views struggle with dynamic relationships and multi-hop queries.
    - Requires complex SQL JOIN chains for topology traversal.
- **Reason Rejected**: Insufficient for sophisticated topology modeling and multi-hop path analysis required in PRD-02.

### 2. Neo4j as Graph Database
- **Pros**:
    - Mature graph database with robust Cypher query language.
    - Strong community support and documentation.
    - Purpose-built for graph traversals and relationships.
- **Cons**:
    - Heavier resource footprint than ArangoDB.
    - Commercial licensing concerns for SaaS deployment.
    - Less flexible document model compared to ArangoDB.
- **Reason Rejected**: ArangoDB's lightweight nature, multi-model capabilities, and open-source licensing align better with ServiceRadar's architecture and deployment model.

### 3. Custom Relationship Tables in Proton
- **Pros**:
    - Avoids introducing a new database dependency.
    - Keeps all data in one system.
    - Simpler architectural footprint.
- **Cons**:
    - Complex to design and maintain.
    - Poor performance for recursive graph queries.
    - Difficult to optimize for path finding.
- **Reason Rejected**: Not scalable or performant for topology-aware use cases requiring complex graph traversals.

### 4. Embedding Collections in ArangoDB
- **Pros**:
    - Simplified queries by having all data in ArangoDB.
    - Reduced need for cross-database correlation.
    - Potentially faster queries with everything in one place.
- **Cons**:
    - Massive data duplication of time-series metrics.
    - Synchronization complexity for high-frequency metrics.
    - ArangoDB not optimized for time-series data.
- **Reason Rejected**: Our hybrid approach with Proton for time-series and ArangoDB for relationships provides better performance characteristics while minimizing duplication.

### 5. No Relationship Modeling
- **Pros**:
    - Simplest approach, no new components or complexity.
    - Continues with current architecture and dataflows.
- **Cons**:
    - Fails to meet topology-aware monitoring requirements.
    - Makes NetFlow-SNMP correlation difficult or impossible.
    - Significantly limits the platform's analytical capabilities.
- **Reason Rejected**: Does not address critical user needs outlined in PRD-02 and PRD-03.

## Next Steps

1. Review and approve this ADR with stakeholders.
2. Coordinate with the core team to align with PRD-04 and PRD-05 implementation timelines.
3. Begin Phase 1 (Data Foundation) implementation by [date].
4. Develop detailed technical specifications for the `discovered_interfaces` stream and ArangoDB collections.
5. Create proof-of-concept for NetFlow-SNMP correlation using the hybrid approach.
6. Finalize SRQL grammar extensions for correlation and topology queries.
