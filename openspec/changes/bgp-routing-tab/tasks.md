## 1. Database Schema & Migration

- [x] 1.1 Create Ecto migration for bgp_routing_info table with all columns (id, timestamp, source_protocol, as_path, bgp_communities, src_ip, dst_ip, total_bytes, total_packets, flow_count, metadata, created_at)
- [x] 1.2 Add TimescaleDB hypertable creation: SELECT create_hypertable('platform.bgp_routing_info', 'timestamp')
- [x] 1.3 Create GIN index on as_path column: idx_bgp_routing_as_path
- [x] 1.4 Create GIN index on bgp_communities column: idx_bgp_routing_communities
- [x] 1.5 Create index on (source_protocol, timestamp DESC): idx_bgp_routing_source
- [x] 1.6 Add bgp_observation_id UUID column to netflow_metrics table (nullable)
- [x] 1.7 Add foreign key constraint from netflow_metrics.bgp_observation_id to bgp_routing_info.id
- [x] 1.8 Create unique index on bgp_routing_info for deduplication: (time_bucket('1 minute', timestamp), source_protocol, as_path, bgp_communities, src_ip, dst_ip)

## 2. Ash Domain - ServiceRadar.BGP

- [x] 2.1 Create ServiceRadar.BGP domain module in elixir/serviceradar_core/lib/serviceradar/bgp/
- [x] 2.2 Create ServiceRadar.BGP.BGPObservation Ash resource for bgp_routing_info table
- [x] 2.3 Add attributes matching schema (timestamp, source_protocol, as_path, bgp_communities, src_ip, dst_ip, aggregations, metadata)
- [x] 2.4 Add authorization policy using SystemActor.system for background processes
- [x] 2.5 Add read action :list with filters for time_range, source_protocol, as_path contains
- [x] 2.6 Add create action :upsert with ON CONFLICT DO UPDATE for aggregation columns
- [x] 2.7 Create ServiceRadar.BGP.Stats query module with get_traffic_by_as/3 function
- [x] 2.8 Add get_top_communities/3 function to Stats module
- [x] 2.9 Add get_path_diversity/2 function to Stats module (unique paths count, avg length)
- [x] 2.10 Add get_as_topology/3 function to Stats module (AS-to-AS connections graph)

## 3. Multi-Protocol Ingestion Pipeline

- [x] 3.1 Create ServiceRadar.BGP.Ingestor module in serviceradar_core
- [x] 3.2 Implement upsert_observation/1 function with ON CONFLICT UPDATE logic
- [x] 3.3 Add batch_upsert_observations/1 for batching up to 1000 observations
- [x] 3.4 Add AS path validation (non-empty, valid AS numbers 1-4294967295)
- [x] 3.5 Add BGP community encoding validation (32-bit integers)
- [x] 3.6 Implement time bucketing to 1-minute intervals for deduplication
- [x] 3.7 Return observation UUID after upsert for flow FK assignment
- [x] 3.8 Add Phoenix.PubSub broadcast to "bgp:observations" topic on create/update
- [x] 3.9 Include metadata in broadcast: {action: :created/:updated, observation_id: id, added_bytes: X}

## 4. NetFlow Integration

- [x] 4.1 Modify ServiceRadar.EventWriter.Processors.NetflowMetrics to extract BGP data (as_path, communities)
- [x] 4.2 Add logic to call BGP.Ingestor.upsert_observation before writing netflow_metrics row
- [x] 4.3 Capture returned observation_id and set netflow_metrics.bgp_observation_id
- [x] 4.4 Handle flows without BGP data (skip Ingestor call, set bgp_observation_id=NULL)
- [x] 4.5 Add sampler_address to BGP observation metadata from NetFlow context
- [x] 4.6 Support IPFIX BGP fields: bgpSourceAsNumber (16), bgpDestinationAsNumber (17), bgpSourceCommunityList (484)
- [x] 4.7 Support NetFlow v9 fields: SRC_AS (16), DST_AS (17)
- [x] 4.8 Implement dual-write during migration: populate BOTH old columns AND new table
- [x] 4.9 Add error handling for BGP.Ingestor failures (log warning, continue with bgp_observation_id=NULL)

## 5. UI - BGP Routing LiveView

- [x] 5.1 Create ServiceRadarWebNGWeb.BGPLive.Index module in web-ng/lib/serviceradar_web_ng_web/live/bgp_live/
- [x] 5.2 Implement mount/3 callback with default time_range "last_1h" and source_protocol filter
- [x] 5.3 Subscribe to Phoenix.PubSub "bgp:observations" topic in mount
- [x] 5.4 Create load_bgp_statistics/1 function calling ServiceRadar.BGP.Stats functions
- [x] 5.5 Add handle_info for PubSub messages to refresh data on new observations
- [x] 5.6 Add handle_event for "filter_by_as" to filter views by clicked AS number
- [x] 5.7 Add handle_event for "filter_by_community" to filter by clicked community
- [x] 5.8 Add handle_event for "change_time_range" to update time window
- [x] 5.9 Add handle_event for "change_source_protocol" filter (netflow/sflow/all)
- [x] 5.10 Create render/1 function with template sections for traffic, communities, topology

## 6. UI - BGP Components

- [x] 6.1 Create ServiceRadarWebNGWeb.BGPLive.Components module
- [x] 6.2 Implement bgp_traffic_by_as_view/1 component (bar chart with percentage bars)
- [x] 6.3 Add AS organization name resolution (client-side or server-side lookup)
- [x] 6.4 Implement bgp_top_communities_view/1 component with decoded community names
- [x] 6.5 Add community decoding: well-known (NO_EXPORT, NO_ADVERTISE) and standard (AS:value)
- [x] 6.6 Implement bgp_path_diversity_panel/1 showing unique paths, avg length, hop distribution
- [x] 6.7 Implement bgp_topology_visualization/1 with SVG graph (nodes=ASes, edges=connections)
- [x] 6.8 Add edge thickness calculation based on traffic volume (stroke_width proportional to bytes)
- [x] 6.9 Add click handlers for AS nodes to highlight connected edges
- [x] 6.10 Add empty state messages when no BGP data available for time range

## 7. Navigation & Routes

- [x] 7.1 Add /bgp-routing route to ServiceRadarWebNGWeb.Router pointing to BGPLive.Index
- [x] 7.2 Add "BGP Routing" tab to observability navigation in LogLive.Index template
- [ ] 7.3 Modify NetflowLive.Visualize to remove inline BGP sections (traffic by AS, communities, topology)
- [ ] 7.4 Add "View BGP Routing →" link in NetflowLive when flow has bgp_observation_id
- [ ] 7.5 Support pre-filtering BGP tab by AS path when navigating from NetFlow flow detail
- [ ] 7.6 Update observability navigation CSS to highlight active tab

## 8. Data Migration & Backfill

- [ ] 8.1 Create data migration to backfill bgp_routing_info from existing netflow_metrics rows
- [ ] 8.2 Group existing netflow_metrics by (time_bucket, as_path, communities, src_ip, dst_ip)
- [ ] 8.3 Aggregate bytes/packets/count for each unique observation in backfill
- [ ] 8.4 INSERT backfilled observations into bgp_routing_info with source_protocol='netflow'
- [ ] 8.5 UPDATE netflow_metrics.bgp_observation_id to reference new bgp_routing_info.id
- [ ] 8.6 Verify all existing BGP flows now have non-NULL bgp_observation_id
- [ ] 8.7 Add data verification query: compare traffic by AS from old columns vs new table

## 9. Testing & Validation

- [ ] 9.1 Write ExUnit tests for ServiceRadar.BGP.Ingestor.upsert_observation/1
- [ ] 9.2 Test ON CONFLICT UPDATE increments aggregation columns correctly
- [ ] 9.3 Write tests for AS path validation (empty path, invalid AS numbers)
- [ ] 9.4 Write tests for BGP.Stats.get_traffic_by_as/3 query
- [ ] 9.5 Write tests for BGP.Stats.get_top_communities/3 query
- [ ] 9.6 Write LiveView tests for BGPLive.Index mount and data loading
- [ ] 9.7 Test PubSub subscription and handle_info updates in BGPLive
- [ ] 9.8 Test NetFlow processor BGP extraction and Ingestor integration
- [ ] 9.9 Manual test: verify /bgp-routing page loads and displays test data
- [ ] 9.10 Manual test: verify AS topology graph renders and is interactive

## 10. Deployment & Cleanup

- [ ] 10.1 Deploy Phase 1: Run migration creating bgp_routing_info table and bgp_observation_id column
- [ ] 10.2 Deploy Phase 1: Deploy NetFlow processor with dual-write enabled
- [ ] 10.3 Deploy Phase 1: Run backfill migration to populate historical data
- [ ] 10.4 Verify: All new flows have bgp_observation_id populated
- [ ] 10.5 Deploy Phase 2: Deploy BGP UI (new /bgp-routing route)
- [ ] 10.6 Deploy Phase 2: Deploy updated NetFlow UI (removed inline BGP, added link)
- [ ] 10.7 Verify: BGP Routing tab shows expected data matching old NetFlow tab
- [ ] 10.8 Monitor: Check for errors in BGP.Ingestor, LiveView crashes, query performance
- [ ] 10.9 Document: Update user docs with BGP Routing tab usage
- [ ] 10.10 Plan Phase 3: Schedule old column drop (netflow_metrics.as_path, bgp_communities) after 30-day stability period
