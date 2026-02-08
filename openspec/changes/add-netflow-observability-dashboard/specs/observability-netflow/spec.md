## ADDED Requirements

### Requirement: NetFlow dashboard workspace
The system SHALL provide a NetFlow observability dashboard that combines summary widgets, visualizations, and a flow table into a single workspace for investigation.

#### Scenario: Operator opens the NetFlow dashboard
- **WHEN** an operator navigates to the NetFlow dashboard
- **THEN** the UI shows summary widgets, at least one traffic visualization, and a paginated flows table
- **AND** the dashboard defaults to a recent time range (e.g., last 5 minutes)

### Requirement: Server-side filtering and pagination for flows
The system SHALL support server-side filtering, sorting, and pagination for the flows table to remain responsive under high-cardinality datasets.

#### Scenario: Apply flow filters without loading all rows
- **WHEN** an operator filters flows by time range and protocol
- **THEN** the server returns only the requested page of results
- **AND** the response includes paging metadata needed to fetch subsequent pages

### Requirement: Data enrichment for flow endpoints
The system SHALL enrich flow endpoints (source and destination IPs) with contextual metadata, including GeoIP location, rDNS hostname, ASN/ISP, and service name tagging for well-known ports.

#### Scenario: Display enriched data in the flow table
- **GIVEN** a flow with source/destination IPs and a destination port
- **WHEN** the flow is displayed in the NetFlow table
- **THEN** the UI shows enriched fields when available (e.g., hostname, country/city, ASN, service name)
- **AND** raw IP/port values remain visible and copyable

### Requirement: Enrichment caching with bounded latency
Enrichment lookups (GeoIP, ASN, rDNS, threat intel) MUST be cached and MUST be time-bounded so cache misses do not block queries beyond a strict timeout.

#### Scenario: rDNS lookup does not stall the UI
- **GIVEN** rDNS lookup is enabled
- **WHEN** a flow row is rendered and the hostname is not cached
- **THEN** the lookup is attempted with a strict timeout
- **AND** the UI remains responsive and shows an uncached placeholder until enrichment resolves

### Requirement: Directionality tagging
The system SHALL label flows as `Inbound`, `Outbound`, or `Internal` using configured “local CIDRs”.

#### Scenario: Internal (east-west) flow classification
- **GIVEN** local CIDRs include the source and destination IP ranges
- **WHEN** a flow is displayed
- **THEN** its directionality is labeled `Internal`

### Requirement: Top talkers and top ports widgets
The NetFlow dashboard SHALL provide widgets for top talkers (by bytes and/or packets) and top ports over the selected time range.

#### Scenario: Top talkers updates with time range
- **WHEN** an operator changes the dashboard time range
- **THEN** the top talkers widget recomputes results for the new window
- **AND** clicking a top talker applies an equivalent filter to the flows table

### Requirement: Traffic time-series visualization
The NetFlow dashboard SHALL provide a time-series chart of traffic volume over time (bytes/sec and/or packets/sec) for the selected time window.

#### Scenario: Time-series chart supports drill-down
- **WHEN** an operator selects a sub-range or series within the time-series visualization
- **THEN** the flows table filters to match that time constraint

### Requirement: Linked drill-down filters
Interactions with visualizations (charts, widgets) SHALL apply global filters that are reflected in the flows table and remain visible/editable in the UI.

#### Scenario: Chart click applies a protocol filter
- **GIVEN** a protocol distribution visualization is present
- **WHEN** an operator clicks the `TCP` segment
- **THEN** the global filter state adds `protocol=tcp`
- **AND** the flows table results update to match

### Requirement: CIDR aggregation mode
The system SHALL provide an option to aggregate flows by subnet (e.g., `/24` or `/16`) to reduce noise in both widgets and table views.

#### Scenario: Operator toggles /24 aggregation
- **WHEN** an operator enables CIDR aggregation at `/24`
- **THEN** the table and widgets group flow endpoints by `/24` rather than individual IPs

### Requirement: Unit auto-scaling
The UI SHALL display bandwidth and byte counts using automatically scaled units (B/KB/MB/GB/TB) with consistent rounding and labels.

#### Scenario: Byte totals displayed in human units
- **WHEN** a widget shows a total byte count
- **THEN** the UI renders the value using an appropriate unit with a consistent format

### Requirement: Flow row detail panel
The UI SHALL provide a detail view for a flow record that surfaces enrichment details (GeoIP, ASN, rDNS), related flows pivots, and copy/export affordances.

#### Scenario: Open detail panel from table row
- **WHEN** an operator clicks a flow row
- **THEN** a side panel (or equivalent) opens showing full flow fields and enrichment details
- **AND** the panel provides one-click actions to pivot (e.g., filter by src_ip, dst_ip, port, ASN)

### Requirement: Optional security intelligence flags
The system SHALL support optionally enabling security intelligence flags for flows, including threat intel matches, anomaly indicators, and port scan heuristics.

#### Scenario: Threat intel match badge
- **GIVEN** a threat intel feed is configured and enabled
- **WHEN** a flow endpoint matches an indicator
- **THEN** the flow row shows a visible warning badge with a short explanation
