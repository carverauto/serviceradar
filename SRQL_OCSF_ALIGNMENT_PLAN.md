# SRQL to OCSF Alignment Plan

## Executive Summary

ServiceRadar's current SRQL implementation needs restructuring to align with the Open Cybersecurity Schema Framework (OCSF). This requires:

1. **Schema Migration**: From stream-based tables to entity-centric data model
2. **Query Language Evolution**: From SQL-like to entity/observable-based searches
3. **Federation Support**: Normalizing data sources into OCSF event classes
4. **API Routing**: Intelligent query planning based on searchable attributes

## Current State vs Target State

### Current ServiceRadar Architecture
- **Data Model**: Stream-based tables (devices, flows, logs, metrics)
- **Storage**: Timeplus Proton streams with materialized views
- **Query**: Direct SQL translation with table mappings
- **Entities**: Loosely defined through table names

### Target OCSF Architecture
- **Data Model**: Event-centric with standardized OCSF classes
- **Storage**: Entity stores with observable indexing
- **Query**: Observable-based searches with automatic routing
- **Entities**: First-class citizens with defined relationships

## Phase 1: Data Model Restructuring

### 1.1 OCSF Event Class Mapping

Map existing ServiceRadar data to OCSF event classes:

```yaml
Current -> OCSF Mapping:
  devices -> Device Inventory Info (discovery.device_inventory_info)
  users -> User Inventory Info (discovery.user_inventory_info)
  flows -> Network Activity (network.network_activity)
  logs -> System Activity (system.system_activity)
  traps -> Detection Finding (findings.detection_finding)
  vulnerabilities -> Vulnerability Finding (findings.vulnerability_finding)
  services -> Application Activity (application.application_activity)
```

### 1.2 Entity/Observable Definition

Define primary observables that span multiple event types:

```yaml
Observables:
  ip_address:
    paths:
      - device.ip
      - device.interfaces[].ip_addresses[]
      - network_activity.src_endpoint.ip
      - network_activity.dst_endpoint.ip
      - connection.remote_ip
  
  mac_address:
    paths:
      - device.mac
      - device.interfaces[].mac
      - network_endpoint.mac
  
  hostname:
    paths:
      - device.hostname
      - device.name
      - user.domain
      - endpoint.hostname
  
  resource_uid:
    paths:
      - device.uid
      - user.uid
      - vulnerability.device_ids[]
  
  username:
    paths:
      - user.name
      - user.email_addr
      - authentication.user.name
  
  cve:
    paths:
      - vulnerability.cve.uid
      - finding.cve_ids[]
```

### 1.3 Database Schema Migration

```sql
-- New entity-centric tables
CREATE TABLE entities.devices (
  uid String,              -- Resource UID (primary key)
  time DateTime64(3),      -- OCSF time field
  name String,             -- Hostname
  ip Array(String),        -- All IP addresses
  mac Array(String),       -- All MAC addresses
  site String,             -- Geo location
  type_id Int32,           -- OCSF device type enum
  os Map(String, String),  -- OS details
  metadata Map(String, String),
  observables Map(String, Array(String)), -- Indexed observables
  raw_data String          -- Original JSON
) ENGINE = VersionedCollapsingMergeTree(sign, version)
ORDER BY (uid, time);

CREATE TABLE entities.users (
  uid String,
  time DateTime64(3),
  name String,             -- Username
  domain String,           -- Hostname/domain
  email_addr String,
  type_id Int32,           -- OCSF user type enum
  metadata Map(String, String),
  observables Map(String, Array(String)),
  raw_data String
) ENGINE = VersionedCollapsingMergeTree(sign, version)
ORDER BY (uid, time);

CREATE TABLE events.network_activity (
  time DateTime64(3),
  start_time DateTime64(3),
  end_time DateTime64(3),
  activity_id Int32,       -- OCSF activity enum
  src_endpoint Nested(
    ip String,
    port Int32,
    mac String,
    hostname String
  ),
  dst_endpoint Nested(
    ip String,
    port Int32,
    mac String,
    hostname String
  ),
  traffic Nested(
    bytes_in Int64,
    bytes_out Int64,
    packets_in Int64,
    packets_out Int64
  ),
  observables Map(String, Array(String)),
  raw_data String
) ENGINE = MergeTree()
ORDER BY (time, src_endpoint.ip, dst_endpoint.ip);

-- Observable index for fast lookups
CREATE TABLE observable_index (
  observable_type String,  -- 'ip_address', 'mac_address', etc.
  observable_value String,
  entity_type String,      -- 'device', 'user', 'network_activity'
  entity_uid String,
  time DateTime64(3),
  path String             -- JSON path to value
) ENGINE = MergeTree()
ORDER BY (observable_type, observable_value, time);
```

## Phase 2: Query Language Evolution

### 2.1 OCSF-Aligned Query Syntax

Extend the parser to support OCSF-aligned queries:

```
# Current SRQL
SHOW devices WHERE ip = '192.168.1.1'

# New OCSF-aligned style
in:devices ip:192.168.1.1
in:devices,users hostname:server01
observable:ip_address value:192.168.1.1
```

### 2.2 Query Grammar Extension

```ocaml
(* Extended AST for OCSF-aligned query support *)
type search_target = 
  | Entity of string list       (* in:devices,users *)
  | Observable of string         (* observable:ip_address *)
  | EventClass of string        (* class:network.dns_activity *)

type search_filter =
  | AttributeFilter of string * operator * value  (* ip:192.168.1.1 *)
  | ObservableFilter of string * value           (* mac:AA:BB:CC:DD:EE:FF *)
  | TimeFilter of time_range                     (* time:last_7d *)
  | TextSearch of string                         (* contains text *)

type query_spec = {
  targets: search_target list;
  filters: search_filter list;
  aggregations: aggregation list option;
  limit: int option;
  sort: sort_spec list option;
}
```

### 2.3 Query Planner

Implement intelligent routing based on searchable attributes:

```ocaml
(* Query planner determines optimal execution path *)
type query_plan =
  | DirectEntity of string * string  (* entity_type, query *)
  | ObservableLookup of string * string * query_plan  (* observable, value, continuation *)
  | Federation of query_plan list  (* parallel searches *)
  | Join of query_plan * query_plan * join_key

let plan_query (q: query_spec) : query_plan =
  match q.targets, q.filters with
  | [Entity ["devices"]], [AttributeFilter ("mac", _, _)] ->
      (* MAC search only supported via direct /devices API *)
      DirectEntity ("devices", build_device_query q)
  
  | [Observable "ip_address"], filters ->
      (* Search all entities with IP addresses *)
      Federation [
        ObservableLookup ("ip_address", extract_ip filters, 
          DirectEntity ("devices", "uid IN (...)")));
        ObservableLookup ("ip_address", extract_ip filters,
          DirectEntity ("network_activity", "time IN (...)"))
      ]
  
  | [Entity ["vulnerabilities"]], [AttributeFilter ("ip", _, _)] ->
      (* Vulnerabilities don't support IP search directly *)
      (* Must pivot through devices first *)
      let device_plan = DirectEntity ("devices", "ip = ...") in
      Join (device_plan, DirectEntity ("vulnerabilities", "device_uid IN (...)"), "uid")
```

## Phase 3: Federation Architecture

### 3.1 Data Source Normalization

```yaml
Data Sources:
  netbox:
    type: external_api
    maps_to: discovery.device_inventory_info
    normalization:
      - source.id -> uid
      - source.primary_ip -> ip[0]
      - source.name -> hostname
  
  snmp:
    type: poller
    maps_to: discovery.device_inventory_info
    enriches: true
    normalization:
      - sysName -> hostname
      - interfaces -> interfaces[]
  
  netflow:
    type: stream
    maps_to: network.network_activity
    normalization:
      - SrcAddr -> src_endpoint.ip
      - DstAddr -> dst_endpoint.ip
      - Bytes -> traffic.bytes_in
```

### 3.2 Result Aggregation

```ocaml
type federated_result = {
  source: string;
  event_class: string;
  confidence: float;  (* Normalization confidence *)
  data: ocsf_event;
}

let aggregate_results (results: federated_result list) : ocsf_event list =
  results
  |> group_by (fun r -> r.data.uid)  (* Group by entity *)
  |> List.map merge_entity_data       (* Merge attributes *)
  |> apply_confidence_scoring         (* Weight by source reliability *)
```

## Phase 4: Implementation Roadmap

### Stage 1: Foundation (Weeks 1-4)
- [ ] Define OCSF event mappings for existing data
- [ ] Create observable index design
- [ ] Prototype entity-centric tables
- [ ] Build OCSF-aligned query parser in OCaml

### Stage 2: Migration (Weeks 5-8)
- [ ] Create migration scripts for existing data
- [ ] Build data normalization pipelines
- [ ] Implement observable extraction
- [ ] Test entity queries

### Stage 3: Query Engine (Weeks 9-12)
- [ ] Implement query planner
- [ ] Add federation support
- [ ] Build result aggregation
- [ ] Create compatibility layer for old SRQL

### Stage 4: Integration (Weeks 13-16)
- [ ] Update API endpoints
- [ ] Modify UI to use new query format
- [ ] Add monitoring for query performance
- [ ] Document new query language

## Technical Considerations

### Performance Impact
- Observable indexing will increase storage by ~30%
- Query planning adds 10-50ms latency
- Federation can parallelize for better performance
- Entity-centric model improves join performance

### Backward Compatibility
- Maintain SRQL v1 translator for 6 months
- Provide query migration tool
- Support both syntaxes initially
- Gradual UI migration

### Storage Requirements
```yaml
Estimated Storage:
  Current: 
    - Streams: 100GB/month
    - Indexes: 20GB/month
  
  OCSF Model:
    - Entities: 80GB/month
    - Events: 60GB/month
    - Observables: 40GB/month
    - Total: 180GB/month (+50%)
```

## Benefits of Alignment

1. **Industry Standard**: OCSF compliance enables interoperability
2. **Powerful Search**: Observable-based search across all data
3. **Smart Routing**: Automatic query optimization
4. **Federation Ready**: Easy integration with external sources
5. **Future Proof**: Aligned with industry leaders (AWS, Splunk, CrowdStrike)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Migration complexity | High | Phased approach with rollback capability |
| Performance regression | Medium | Extensive benchmarking before cutover |
| Storage increase | Medium | Implement data retention policies |
| Learning curve | Low | Comprehensive documentation and training |

## Success Metrics

- Query response time < 500ms for 95% of queries
- Observable search coverage > 90% of use cases  
- Federation accuracy > 95%
- Zero data loss during migration
- User adoption > 80% within 3 months

## Next Steps

1. **Validate Approach**: Review with team and stakeholders
2. **Prototype**: Build proof-of-concept for device queries
3. **Benchmark**: Compare performance vs current system
4. **Plan Migration**: Detailed migration strategy
5. **Begin Implementation**: Start with Stage 1 foundation

## Appendix: Query Examples

```bash
# Find all devices with specific IP
in:devices ip:192.168.1.1

# Search across devices and users for hostname
in:devices,users hostname:server01

# Find vulnerabilities for a device (requires pivot)
in:devices ip:192.168.1.1 -> in:vulnerabilities device.uid:*

# Observable search (searches all entities)
observable:mac_address value:AA:BB:CC:DD:EE:FF

# Time-bounded search
in:network time:last_24h src_endpoint.ip:10.0.0.1

# Aggregation query
in:devices site:headquarters | stats count() by os.name
```
