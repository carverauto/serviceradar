## ADDED Requirements

### Requirement: MTR Time-Window Comparison
The web UI SHALL allow operators to compare aggregate MTR diagnostics across two selected time windows for matching target, source-agent, protocol, and reachability filters.

#### Scenario: Operator compares today so far to yesterday
- **GIVEN** retained MTR traces exist for today and yesterday
- **WHEN** the operator selects the `Today vs Yesterday Full Day` comparison preset
- **THEN** the UI compares today's elapsed window from local midnight through now against yesterday's full 24-hour day
- **AND** it shows sample counts for both windows
- **AND** it states that the baseline window covers a different amount of elapsed time
- **AND** it provides a direct option to compare against yesterday's matching elapsed window
- **AND** it shows deltas for reachability, average last-hop latency, average hop loss, average hop depth, and trace volume

#### Scenario: Operator normalizes today against yesterday same hours
- **GIVEN** retained MTR traces exist for today and yesterday
- **WHEN** the operator selects the `Today vs Yesterday Same Hours` comparison preset
- **THEN** the UI compares today's elapsed window from local midnight through now against yesterday's matching elapsed window
- **AND** it labels the comparison as elapsed-aligned
- **AND** it shows deltas for reachability, average last-hop latency, average hop loss, average hop depth, and trace volume

#### Scenario: Operator compares rolling 24-hour windows
- **GIVEN** retained MTR traces exist for the last 48 hours
- **WHEN** the operator selects the `Rolling 24h vs Previous 24h` comparison preset
- **THEN** the UI compares the 24 hours ending now against the immediately preceding 24 hours
- **AND** it labels the comparison as elapsed-aligned
- **AND** it shows deltas for reachability, average last-hop latency, average hop loss, average hop depth, and trace volume

#### Scenario: Operator compares a selected incident window
- **GIVEN** retained MTR traces exist around an incident
- **WHEN** the operator selects custom start and end times for both comparison windows
- **THEN** the UI compares only traces inside those windows
- **AND** the selected filters are applied to both windows

### Requirement: MTR Comparison Timeline Selection
The web UI SHALL provide a retained-history timeline on the MTR comparison page that helps operators select and refine comparison windows.

#### Scenario: Operator selects a range from recent history
- **GIVEN** retained MTR traces exist over the last week
- **WHEN** the operator opens time-window comparison
- **THEN** the UI shows a timeline of trace activity and reachability over the retained recent range
- **AND** the operator can select or adjust a window to drill into more detailed comparison results

#### Scenario: Operator drills into a timeline bucket
- **GIVEN** an availability timeline is shown for a compared MTR window
- **WHEN** the operator hovers over a timeline bucket
- **THEN** the UI shows the bucket day, start time, end time, trace count, reached count, and failed count
- **AND** when the operator selects the bucket, the UI navigates to the MTR diagnostics trace list filtered to that bucket and the active comparison filters

#### Scenario: Timeline handles sparse periods
- **GIVEN** one compared window has fewer samples than the other
- **WHEN** the comparison renders
- **THEN** the UI clearly shows the sample count difference
- **AND** it does not imply that missing samples are successful or failed traces

### Requirement: MTR Aggregate Path Comparison
The web UI SHALL compare dominant route signatures across selected MTR time windows and expose representative traces for inspection.

#### Scenario: Dominant path changes between windows
- **GIVEN** the most common ordered hop sequence differs between two selected windows
- **WHEN** the operator views aggregate comparison
- **THEN** the UI highlights route signature changes
- **AND** it shows representative trace links from each window
- **AND** it reports how many traces used each dominant route

#### Scenario: Source-agent-specific path change
- **GIVEN** multiple source agents have traces in the compared windows
- **WHEN** only one source agent shows a route or reachability change
- **THEN** the UI identifies that source agent as the affected source
- **AND** it distinguishes that from a broad target outage across all sources

## MODIFIED Requirements

### Requirement: MTR Results Page
The web UI SHALL provide a dedicated MTR diagnostics page listing retained traces with paginated browsing, drill-down to hop-by-hop detail, trace-to-trace path comparison, time-window aggregate comparison, native visual diagnostics, and on-demand trace execution.

#### Scenario: Retained traces list is paginated
- **WHEN** the operator navigates to the MTR diagnostics page
- **THEN** a paginated table of retained MTR traces is displayed with target, source agent, hop count, reachability, and timestamp
- **AND** traces are filterable by target, agent, protocol, reachability, and time range
- **AND** the table can browse beyond the first recent page until all matching retained traces have been exhausted

#### Scenario: Trace detail drill-down
- **WHEN** the operator selects a trace from the list
- **THEN** a hop-by-hop table is displayed with: hop number, IP, hostname, ASN/org, loss%, avg/min/max RTT, jitter, MPLS labels
- **AND** per-hop latency sparklines show recent trend when enough retained history exists

#### Scenario: Path comparison
- **WHEN** the operator selects two traces to the same target
- **THEN** changed hops are highlighted (IP changes, new hops, missing hops)
- **AND** latency differences per hop are shown

#### Scenario: Aggregate time-window comparison
- **WHEN** the operator compares two MTR time windows
- **THEN** aggregate reachability, latency, loss, hop-depth, route-signature, and source-agent differences are shown
- **AND** comparison visuals can drill down to the trace and hop evidence behind them
- **AND** window summary cards, metric values, route signatures, and source-agent rows are selectable wherever the backing traces can be filtered or inspected

#### Scenario: Native visual summaries remain evidence-backed
- **GIVEN** the MTR diagnostics page renders trend, heatmap, reachability, or path-change visuals
- **WHEN** the operator selects a visual segment, point, bucket, or row
- **THEN** the UI exposes the trace and hop evidence behind that visual
