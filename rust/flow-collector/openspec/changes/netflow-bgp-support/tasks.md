## 1. Protobuf and Data Structures

- [x] 1.1 Generate Elixir protobuf code for FlowMessage from flow.proto
- [x] 1.2 Add FlowMessage module to elixir/serviceradar_core/lib/serviceradar/proto/flow.pb.ex
- [x] 1.3 Verify protobuf enums (FlowType, LayerStack) are properly defined

## 2. Processor Implementation

- [x] 2.1 Create NetFlowMetrics processor module with @behaviour ServiceRadar.EventWriter.Processor
- [x] 2.2 Implement parse_message/1 to decode FlowMessage protobuf
- [x] 2.3 Implement ip_bytes_to_inet/1 for IPv4 and IPv6 address conversion
- [x] 2.4 Implement extract_as_path/1 with uint32→int32 conversion
- [x] 2.5 Implement extract_bgp_communities/1 with uint32→int32 conversion
- [x] 2.6 Implement extract_timestamp/1 with flow start/received time fallback
- [x] 2.7 Implement build_metadata/1 to collect unmapped fields into JSONB
- [x] 2.8 Implement process_batch/1 to insert rows into netflow_metrics table
- [x] 2.9 Add error handling for protobuf decode failures
- [x] 2.10 Add error handling for database insert failures

## 3. EventWriter Integration

- [x] 3.1 Add NETFLOW_RAW stream config to Config.default_streams/0
- [x] 3.2 Set batch_size=50 and batch_timeout=500 for NETFLOW_RAW stream
- [x] 3.3 Add netflow_raw batcher rule to Pipeline.batcher_rules/0
- [x] 3.4 Add get_processor(:netflow_raw) mapping to NetFlowMetrics processor
- [x] 3.5 Verify routing: flows.raw.netflow subject → netflow_raw batcher → NetFlowMetrics processor

## 4. Database Schema

- [x] 4.1 Create migration for netflow_metrics hypertable
- [x] 4.2 Add timestamp column (timestamptz, NOT NULL) as hypertable partition key
- [x] 4.3 Add INET columns: src_ip, dst_ip, sampler_address
- [x] 4.4 Add INTEGER columns: src_port, dst_port, protocol
- [x] 4.5 Add BIGINT columns: bytes_total, packets_total
- [x] 4.6 Add INTEGER[] columns: as_path, bgp_communities
- [x] 4.7 Add TEXT column: partition (for multi-tenant isolation)
- [x] 4.8 Add JSONB column: metadata
- [x] 4.9 Create GIN index on as_path: idx_netflow_metrics_as_path
- [x] 4.10 Create GIN index on bgp_communities: idx_netflow_metrics_bgp_communities
- [x] 4.11 Create BTREE index on timestamp: idx_netflow_metrics_timestamp
- [x] 4.12 Add unique constraint to prevent duplicate flows (if applicable)
- [ ] 4.13 Run migration in development environment
- [ ] 4.14 Verify hypertable chunk interval (default 7 days)

## 5. Testing

- [x] 5.1 Unit test: NetFlowMetrics.parse_message/1 with valid FlowMessage
- [x] 5.2 Unit test: NetFlowMetrics.parse_message/1 with invalid protobuf
- [x] 5.3 Unit test: ip_bytes_to_inet/1 with IPv4 address (4 bytes)
- [x] 5.4 Unit test: ip_bytes_to_inet/1 with IPv6 address (16 bytes)
- [x] 5.5 Unit test: ip_bytes_to_inet/1 with invalid length
- [x] 5.6 Unit test: extract_as_path/1 with normal values
- [x] 5.7 Unit test: extract_as_path/1 with values > max int32 (capping)
- [x] 5.8 Unit test: extract_as_path/1 with empty/nil
- [x] 5.9 Unit test: extract_bgp_communities/1 with normal values
- [x] 5.10 Unit test: extract_bgp_communities/1 with values > max int32
- [x] 5.11 Unit test: extract_timestamp/1 with flow_start_ns
- [x] 5.12 Unit test: extract_timestamp/1 with received_ns fallback
- [x] 5.13 Unit test: extract_timestamp/1 with current time fallback
- [x] 5.14 Unit test: build_metadata/1 with interface fields
- [x] 5.15 Unit test: build_metadata/1 with empty metadata
- [x] 5.16 Integration test: Send FlowMessage to NATS flows.raw.netflow (test written)
- [x] 5.17 Integration test: Verify row inserted into netflow_metrics table (test written)
- [x] 5.18 Integration test: Verify BGP fields populated correctly (test written)
- [x] 5.19 Integration test: Test GIN query WHERE as_path @> ARRAY[64512] (test written)
- [x] 5.20 Integration test: Test GIN query WHERE bgp_communities @> ARRAY[...] (test written)
- [x] 5.21 Load test: Send 10,000 flows, verify batch processing performance (test written)

## 6. UI Components - Flow Display

- [x] 6.1 Add AS path display to flow detail view (AS1 → AS2 → AS3 format)
- [x] 6.2 Add BGP communities display to flow detail view
- [x] 6.3 Format BGP communities as ASN:value (upper 16:lower 16 bits)
- [x] 6.4 Add well-known community name mapping (NO_EXPORT, NO_ADVERTISE, etc.)
- [x] 6.5 Handle flows without BGP data gracefully (show "No BGP information")
- [x] 6.6 Add tooltips for AS numbers and BGP community values

## 7. UI Components - Filtering

- [x] 7.1 Add AS number filter input to NetFlow search
- [x] 7.2 Parse as_path:[64512] filter syntax
- [x] 7.3 Convert AS filter to WHERE as_path @> ARRAY[...] query
- [x] 7.4 Add BGP community filter input
- [x] 7.5 Parse bgp_community:[65000:100] filter syntax (ASN:value)
- [x] 7.6 Convert BGP community filter to WHERE bgp_communities @> ARRAY[...]
- [x] 7.7 Add well-known community quick filter buttons (NO_EXPORT, etc.)
- [x] 7.8 Add clear filter functionality
- [x] 7.9 Display active BGP filters with remove buttons

## 8. UI Components - BGP Statistics Panel

- [x] 8.1 Create BGP statistics panel component
- [x] 8.2 Auto-show panel when BGP filters are applied
- [x] 8.3 Implement "Traffic by AS" aggregation query (GROUP BY unnest(as_path))
- [x] 8.4 Display top 10 AS numbers with bar chart
- [x] 8.5 Show total bytes, packets, and flow count per AS
- [x] 8.6 Implement "Top BGP Communities" aggregation query
- [x] 8.7 Display top 10 communities with flow counts
- [x] 8.8 Implement "AS Path Diversity" metrics query
- [x] 8.9 Display unique paths count, average length, max length
- [x] 8.10 Handle empty results gracefully (show "No BGP data in selected flows")
- [x] 8.11 Fix column names in NetflowBGPStats queries (octets→bytes_total, packets→packets_total)

## 9. UI Components - AS Topology Graph

- [x] 9.1 Create AS topology graph component (SVG or D3.js)
- [x] 9.2 Implement AS connections query (generate_series for path segments)
- [x] 9.3 Build graph nodes from unique AS numbers in results
- [x] 9.4 Build graph edges from AS path segments with traffic totals
- [x] 9.5 Size nodes by total traffic volume
- [x] 9.6 Size edges by connection traffic volume
- [ ] 9.7 Add hover tooltips for nodes (AS number, bytes, flow count)
- [ ] 9.8 Add hover tooltips for edges (connection bytes, flow count)
- [ ] 9.9 Highlight connected edges on node hover
- [ ] 9.10 Add click-to-filter on AS node (apply as_path:[X] filter)
- [ ] 9.11 Add graph layout algorithm (force-directed or hierarchical)

## 10. UI Components - Data Export

- [ ] 10.1 Add AS path column to CSV export
- [ ] 10.2 Format AS path as comma-separated list (64512,64515)
- [ ] 10.3 Add BGP communities column to CSV export
- [ ] 10.4 Include as_path array in JSON export
- [ ] 10.5 Include bgp_communities array in JSON export

## 11. Documentation

- [x] 11.1 Document BGP filter syntax in UI help/guide (docs/docs/netflow.md)
- [x] 11.2 Add examples: as_path:[64512], bgp_community:[65000:100]
- [x] 11.3 Document well-known BGP communities (NO_EXPORT, NO_ADVERTISE, etc.)
- [x] 11.4 Add developer notes about uint32→int32 conversion
- [x] 11.5 Document GIN index usage and performance characteristics
- [x] 11.6 Update ServiceRadar architecture docs with raw metrics flow (dual pipeline architecture)
- [x] 11.7 Add NetFlowMetrics processor to EventWriter documentation (netflow_metrics_processor.md)

## 12. Deployment

- [ ] 12.1 Run database migration in staging environment
- [ ] 12.2 Deploy core-elx with NetFlowMetrics processor to staging
- [ ] 12.3 Verify NATS consumer connects to flows.raw.netflow
- [ ] 12.4 Verify flows appear in netflow_metrics table
- [ ] 12.5 Test BGP filtering and statistics in staging UI
- [ ] 12.6 Monitor EventWriter telemetry for batch processing metrics
- [ ] 12.7 Run database migration in production
- [ ] 12.8 Deploy core-elx to production
- [ ] 12.9 Verify production data flow
- [ ] 12.10 Remove zen-consumer from deployment (if applicable)

## 13. Code Cleanup

- [x] 13.1 Delete redundant Go BGP REST API (handler, tests, queries)
- [x] 13.2 Delete Go netflow-ingestor consumer (main, service, tests)
- [x] 13.3 Delete Go NetFlow models (pkg/models/netflow.go)
- [x] 13.4 Delete Go DB layer (pkg/db/netflow.go, cnpg_netflow.go)
- [x] 13.5 Remove StoreNetflowMetrics from pkg/db/interfaces.go
- [x] 13.6 Remove ErrNetflowMetricNil from pkg/db/errors.go
- [x] 13.7 Update pkg/db/mock_db.go to remove NetFlow methods
- [x] 13.8 Run go mod tidy to clean up unused dependencies
- [x] 13.9 Verify Go packages build successfully
- [x] 13.10 Verify Rust netflow-collector tests pass (46 tests)
- [x] 13.11 Verify no remaining NetFlow references in Go code
- [x] 13.12 Confirm single-stack Elixir/Broadway architecture
