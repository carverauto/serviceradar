## ADDED Requirements

### Requirement: BGP Routing observability tab
The system SHALL provide a dedicated "BGP Routing" top-level tab in the observability interface accessible at /bgp-routing.

#### Scenario: Navigate to BGP Routing tab
- **WHEN** user clicks "BGP Routing" in observability navigation
- **THEN** system displays BGPLive.Index page with AS topology visualization

#### Scenario: Tab visible for authenticated users
- **WHEN** authenticated user views observability page
- **THEN** system shows "BGP Routing" tab alongside NetFlow, SNMP, DNS tabs

### Requirement: Traffic by AS visualization
The system SHALL display bar chart showing total traffic (bytes) aggregated by AS number across all data sources.

#### Scenario: Display top ASes by traffic
- **WHEN** BGP Routing tab loads
- **THEN** system displays top 10 ASes sorted by total bytes with percentage bars

#### Scenario: Click AS to filter
- **WHEN** user clicks AS number in traffic chart
- **THEN** system filters all views to show only observations containing that AS in path

#### Scenario: Show AS organization name
- **WHEN** traffic chart displays AS 8075 (Microsoft)
- **THEN** system shows "AS 8075 (Microsoft)" with resolved organization name

### Requirement: BGP communities analysis
The system SHALL display top BGP communities with traffic statistics and decoded names.

#### Scenario: Display top communities
- **WHEN** BGP Routing tab loads
- **THEN** system displays top 10 BGP communities sorted by total bytes

#### Scenario: Decode well-known communities
- **WHEN** observation has community 4294967041 (NO_EXPORT)
- **THEN** system displays "NO_EXPORT (4294967041)"

#### Scenario: Decode standard communities
- **WHEN** observation has community 6553800 (100:200)
- **THEN** system displays "100:200 (6553800)"

#### Scenario: Filter by community
- **WHEN** user clicks community "NO_EXPORT"
- **THEN** system filters views to show only observations with that community

### Requirement: AS path diversity metrics
The system SHALL display AS path diversity statistics showing unique paths, average path length, and hop distribution.

#### Scenario: Display unique path count
- **WHEN** BGP Routing tab loads
- **THEN** system shows "X unique AS paths observed" from bgp_routing_info

#### Scenario: Display average path length
- **WHEN** BGP data includes paths of varying lengths
- **THEN** system calculates and displays "Average path length: Y hops"

#### Scenario: Display hop distribution
- **WHEN** BGP Routing tab loads
- **THEN** system shows histogram of path lengths (2 hops: 30%, 3 hops: 50%, 4+ hops: 20%)

### Requirement: AS topology graph visualization
The system SHALL display interactive network graph showing AS-to-AS connections with edge thickness representing traffic volume.

#### Scenario: Display AS connections
- **WHEN** BGP Routing tab loads
- **THEN** system renders graph with nodes for each AS and edges for adjacent ASes in paths

#### Scenario: Edge thickness by traffic
- **WHEN** AS 64512 → AS 64513 carries 100MB and AS 64513 → AS 8075 carries 50MB
- **THEN** system renders first edge thicker than second edge proportionally

#### Scenario: Interactive node selection
- **WHEN** user clicks AS node in topology graph
- **THEN** system highlights connected edges and updates statistics for selected AS

#### Scenario: Empty state for no BGP data
- **WHEN** no BGP observations exist in current time range
- **THEN** system displays "No BGP routing data available for selected time range"

### Requirement: Multi-protocol source filtering
The system SHALL allow filtering BGP observations by source protocol (NetFlow, sFlow, BGP peering).

#### Scenario: Filter to NetFlow sources only
- **WHEN** user selects "NetFlow" protocol filter
- **THEN** system queries bgp_routing_info WHERE source_protocol='netflow' and updates all visualizations

#### Scenario: Show all sources by default
- **WHEN** BGP Routing tab loads
- **THEN** system displays data from all source protocols combined

### Requirement: Time range filtering
The system SHALL support time range selection for BGP observation queries with default of last 1 hour.

#### Scenario: Default time range
- **WHEN** user navigates to BGP Routing tab
- **THEN** system queries bgp_routing_info for last 1 hour (default)

#### Scenario: Custom time range selection
- **WHEN** user selects "Last 24 hours" time range
- **THEN** system updates all visualizations with observations from last 24 hours

### Requirement: Real-time updates via PubSub
The system SHALL subscribe to Phoenix PubSub "bgp:observations" topic and update visualizations when new BGP data arrives.

#### Scenario: New BGP observation received
- **WHEN** NetFlow processor writes new bgp_routing_info record
- **THEN** system broadcasts to "bgp:observations" topic and LiveView updates traffic charts

#### Scenario: LiveView subscription on mount
- **WHEN** BGP Routing tab loads
- **THEN** system subscribes socket to "bgp:observations" PubSub topic

### Requirement: Link from NetFlow to BGP tab
The system SHALL provide navigation link from NetFlow observability tab to BGP Routing tab for flows with BGP data.

#### Scenario: NetFlow shows BGP available indicator
- **WHEN** NetFlow tab displays flow with bgp_observation_id
- **THEN** system shows "View BGP Routing →" link

#### Scenario: Click BGP link from NetFlow
- **WHEN** user clicks "View BGP Routing" from NetFlow flow detail
- **THEN** system navigates to BGP Routing tab with AS path pre-filtered from that flow
