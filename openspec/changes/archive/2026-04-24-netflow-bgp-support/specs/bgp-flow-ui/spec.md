## ADDED Requirements

### Requirement: Display AS path for flows
The UI SHALL display the AS path sequence for flows that contain BGP routing information.

#### Scenario: Flow with AS path displayed
- **WHEN** a user views a flow record that contains an `as_path` field with values
- **THEN** the UI SHALL display the AS path as a formatted sequence (e.g., "AS64512 → AS64513 → AS64514")

#### Scenario: Flow without AS path
- **WHEN** a user views a flow record that does not contain AS path information
- **THEN** the UI SHALL not display an AS path section or show "No AS path data"

#### Scenario: Long AS path truncation
- **WHEN** an AS path contains more than 10 AS numbers
- **THEN** the UI SHALL display the first 5 and last 5 AS numbers with "..." between them, and provide a way to expand the full path

### Requirement: Display BGP communities for flows
The UI SHALL display BGP community attributes in human-readable format.

#### Scenario: Flow with communities displayed
- **WHEN** a user views a flow record that contains `bgp_communities` field with values
- **THEN** the UI SHALL decode and display each community as "AS:value" format (e.g., "65000:100")

#### Scenario: Multiple communities displayed
- **WHEN** a flow has multiple BGP community values
- **THEN** the UI SHALL display all communities as a comma-separated list or tag-style badges

#### Scenario: Well-known communities
- **WHEN** a BGP community matches a well-known value (e.g., NO_EXPORT, NO_ADVERTISE)
- **THEN** the UI SHALL display the human-readable name instead of the numeric value

### Requirement: Filter flows by BGP attributes
The UI SHALL allow users to filter flow data based on BGP routing information.

#### Scenario: Filter by AS number in path
- **WHEN** a user enters an AS number in the filter field
- **THEN** the UI SHALL display only flows where that AS appears in the AS path

#### Scenario: Filter by BGP community
- **WHEN** a user enters a BGP community value (e.g., "65000:100")
- **THEN** the UI SHALL display only flows containing that community

#### Scenario: Combine AS and community filters
- **WHEN** a user applies both AS number and community filters
- **THEN** the UI SHALL display flows matching both criteria (AND logic)

### Requirement: Visualize AS path topology
The UI SHALL provide a visual representation of AS path routing patterns for network flows.

#### Scenario: AS path graph display
- **WHEN** a user views flows with BGP data over a time period
- **THEN** the UI SHALL display a graph showing AS path sequences and traffic volume per path

#### Scenario: Click AS node for details
- **WHEN** a user clicks an AS number in the visualization
- **THEN** the UI SHALL show flows traversing that AS and related statistics (bytes, packets, flow count)

#### Scenario: No BGP data available
- **WHEN** no flows in the selected time range contain BGP information
- **THEN** the UI SHALL display a message indicating BGP visualization is unavailable

### Requirement: Display BGP metrics and statistics
The UI SHALL aggregate and display BGP-related traffic metrics.

#### Scenario: Traffic by AS
- **WHEN** a user views BGP traffic statistics
- **THEN** the UI SHALL show total bytes/packets per AS number in the dataset

#### Scenario: Top BGP communities
- **WHEN** a user views BGP community statistics
- **THEN** the UI SHALL display the most common BGP communities and their associated traffic volume

#### Scenario: AS path diversity
- **WHEN** a user views routing diversity metrics
- **THEN** the UI SHALL show the number of unique AS paths observed and the most common paths

### Requirement: Export BGP flow data
The UI SHALL allow users to export flow data including BGP routing information.

#### Scenario: CSV export with BGP fields
- **WHEN** a user exports flow data to CSV format
- **THEN** the export SHALL include AS path and BGP community columns

#### Scenario: JSON export with BGP fields
- **WHEN** a user exports flow data to JSON format
- **THEN** the export SHALL include `as_path` and `bgp_communities` arrays in the JSON structure

#### Scenario: Export filtered BGP flows
- **WHEN** a user applies BGP-based filters and exports the results
- **THEN** the export SHALL contain only the filtered flows with all BGP metadata
