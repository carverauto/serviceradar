## ADDED Requirements

### Requirement: Display AS path in flow details
The NetFlow UI MUST display the AS path for each flow record in a human-readable format with routing arrows.

#### Scenario: Two-hop AS path display
- **WHEN** Flow has `as_path` = [64512, 64515]
- **THEN** UI displays "AS 64512 → AS 64515"

#### Scenario: Multi-hop AS path display
- **WHEN** Flow has `as_path` = [64512, 64513, 64514, 15169]
- **THEN** UI displays "AS 64512 → AS 64513 → AS 64514 → AS 15169" with arrows between each hop

#### Scenario: No AS path
- **WHEN** Flow has `as_path` = NULL
- **THEN** UI displays "No BGP routing information" or hides the BGP section

### Requirement: Display BGP communities in flow details
The NetFlow UI MUST display BGP community tags for each flow record.

#### Scenario: Standard community format
- **WHEN** Flow has `bgp_communities` = [4259840100]
- **THEN** UI displays community in "ASN:value" format (e.g., "65000:100")

#### Scenario: Multiple communities
- **WHEN** Flow has `bgp_communities` = [4259840100, 4259840200]
- **THEN** UI displays comma-separated list of communities

#### Scenario: Well-known communities
- **WHEN** Flow has well-known community value (e.g., 0xFFFFFF01 for NO_EXPORT)
- **THEN** UI displays human-readable name "NO_EXPORT" with value in tooltip

#### Scenario: No communities
- **WHEN** Flow has `bgp_communities` = NULL
- **THEN** UI displays "None" for BGP communities field

### Requirement: Filter flows by AS number
The NetFlow UI MUST allow users to filter flows by AS numbers that appear anywhere in the AS path.

#### Scenario: Filter by single AS number
- **WHEN** User enters filter `as_path:[64512]`
- **THEN** UI queries `WHERE as_path @> ARRAY[64512]`
- **THEN** Results show only flows traversing AS 64512

#### Scenario: Filter by multiple AS numbers (AND)
- **WHEN** User enters filter `as_path:[64512,64515]`
- **THEN** UI queries `WHERE as_path @> ARRAY[64512, 64515]`
- **THEN** Results show only flows where path contains both AS numbers

#### Scenario: Clear AS filter
- **WHEN** User removes AS filter
- **THEN** UI removes `as_path` constraint from query
- **THEN** Results show all flows again

### Requirement: Filter flows by BGP community
The NetFlow UI MUST allow users to filter flows by BGP community tags.

#### Scenario: Filter by community value
- **WHEN** User enters filter `bgp_community:[4259840100]`
- **THEN** UI queries `WHERE bgp_communities @> ARRAY[4259840100]`
- **THEN** Results show only flows tagged with that community

#### Scenario: Filter by ASN:value notation
- **WHEN** User enters filter `bgp_community:[65000:100]`
- **THEN** UI converts to integer (4259840100) and queries
- **THEN** Results show flows with matching community

#### Scenario: Filter by well-known community name
- **WHEN** User selects "NO_EXPORT" from well-known communities dropdown
- **THEN** UI applies filter for 0xFFFFFF01 value
- **THEN** Results show flows with NO_EXPORT community

### Requirement: Show BGP statistics panel
The NetFlow UI MUST display aggregate BGP statistics when BGP filters are applied or when viewing flows with BGP data.

#### Scenario: Traffic by AS number
- **WHEN** User views flows with AS path data
- **THEN** UI displays top 10 AS numbers by total bytes
- **THEN** Each AS shows total bytes, packets, and flow count
- **THEN** Bar chart visualizes relative traffic volume

#### Scenario: Top BGP communities
- **WHEN** User views flows with BGP community data
- **THEN** UI displays top 10 BGP communities by flow count
- **THEN** Communities are shown in ASN:value format

#### Scenario: AS path diversity metrics
- **WHEN** User views flows with AS path data
- **THEN** UI displays count of unique AS paths
- **THEN** UI displays average path length
- **THEN** UI displays maximum path length observed

#### Scenario: No BGP data
- **WHEN** Filtered flows have no AS path or BGP community data
- **THEN** UI displays message "No BGP routing information in selected flows"
- **THEN** BGP statistics panel is hidden or grayed out

### Requirement: Visualize AS topology graph
The NetFlow UI MUST display a topology graph showing AS-to-AS connections based on observed AS paths.

#### Scenario: Two-node topology
- **WHEN** Flows have AS paths like [64512, 64515] and [64512, 64513]
- **THEN** UI displays graph with 3 nodes (64512, 64515, 64513)
- **THEN** Edges show 64512→64515 and 64512→64513
- **THEN** Edge labels show total bytes for each connection

#### Scenario: Complex topology
- **WHEN** Flows have diverse multi-hop AS paths
- **THEN** UI aggregates edges from all path segments
- **THEN** Node size reflects total traffic volume
- **THEN** Edge thickness reflects connection traffic volume

#### Scenario: Interactive graph
- **WHEN** User hovers over AS node
- **THEN** UI highlights incoming and outgoing edges
- **THEN** Tooltip shows AS number, total bytes, and flow count

#### Scenario: Click to filter
- **WHEN** User clicks an AS node in topology graph
- **THEN** UI applies filter `as_path:[<clicked_as>]`
- **THEN** Results refresh to show only flows traversing that AS

### Requirement: Auto-load BGP panel on filter
The NetFlow UI MUST automatically display the BGP statistics panel when users apply AS path or BGP community filters.

#### Scenario: AS filter triggers BGP panel
- **WHEN** User applies filter `as_path:[64512]`
- **THEN** UI shows BGP statistics panel
- **THEN** Statistics are computed for filtered results

#### Scenario: BGP filter removed hides panel
- **WHEN** User removes all BGP-related filters
- **THEN** UI may hide BGP statistics panel (implementation decision)
- **THEN** Main flow list remains visible

### Requirement: Query BGP aggregations efficiently
The NetFlow UI backend MUST execute aggregate queries on `netflow_metrics` table efficiently using GIN indexes and array operations.

#### Scenario: Traffic by AS query
- **WHEN** UI requests traffic by AS aggregation
- **THEN** Backend executes query using `unnest(as_path)` and `GROUP BY`
- **THEN** Query completes in < 1 second for 1M rows

#### Scenario: AS topology query
- **WHEN** UI requests AS connections for topology graph
- **THEN** Backend executes query with `generate_series()` for path segments
- **THEN** Returns source AS, destination AS, and traffic totals

#### Scenario: GIN index utilized
- **WHEN** UI filters by `as_path @> ARRAY[64512]` or `bgp_communities @> ARRAY[...]`
- **THEN** PostgreSQL query planner uses GIN index
- **THEN** Filter query completes in < 500ms for 1M rows

### Requirement: Handle flows without BGP data gracefully
The NetFlow UI MUST handle flows without BGP routing information without errors or confusion.

#### Scenario: Mixed BGP and non-BGP flows
- **WHEN** Results contain flows with and without AS path data
- **THEN** UI displays BGP fields only for flows that have the data
- **THEN** Flows without BGP data show "No BGP information" in detail view

#### Scenario: Filter excludes non-BGP flows
- **WHEN** User applies AS path filter
- **THEN** Results automatically exclude flows where `as_path IS NULL`
- **THEN** UI indicates count of excluded flows (e.g., "12 flows without BGP data hidden")

### Requirement: Export flows with BGP data
The NetFlow UI MUST include BGP fields (AS path, BGP communities) in CSV/JSON exports of flow data.

#### Scenario: CSV export includes BGP columns
- **WHEN** User exports filtered flows to CSV
- **THEN** CSV includes columns "AS Path" and "BGP Communities"
- **THEN** AS path column contains comma-separated AS numbers (e.g., "64512,64515")
- **THEN** BGP communities column contains comma-separated values

#### Scenario: JSON export includes BGP arrays
- **WHEN** User exports flows to JSON
- **THEN** JSON includes `as_path` as array of integers
- **THEN** JSON includes `bgp_communities` as array of integers
