## ADDED Requirements

### Requirement: Reusable Flow Stat Components
The web-ng UI SHALL provide a `flow_stat_components` module containing pure Phoenix function components for displaying flow statistics. Components MUST accept data via assigns (not fetch data internally) and emit drill-down events via configurable callback attrs. Components MUST render correctly in both light and dark daisyUI themes.

#### Scenario: Stat card renders KPI with trend
- **WHEN** a LiveView renders `<.stat_card title="Total Bandwidth" value={@bandwidth} unit="bps" trend={+12.5} />`
- **THEN** the card displays the title, formatted value with SI prefix, unit label, and a trend indicator (up/down arrow with percentage)

#### Scenario: Top-N table renders ranked rows with drill-down
- **WHEN** a LiveView renders `<.top_n_table rows={@top_talkers} columns={[:rank, :ip, :bytes, :packets]} on_row_click={&handle_drill_down/1} />`
- **THEN** the table displays numbered rows sorted by the ranking metric
- **AND** clicking a row invokes the callback with the row data

#### Scenario: Stat components embedded in device details
- **GIVEN** the device details flows tab LiveView
- **WHEN** it renders `<.top_n_table>` and `<.stat_card>` with device-scoped flow data
- **THEN** the components render identically to their dashboard usage with no code duplication

#### Scenario: Traffic sparkline renders inline mini-chart
- **WHEN** a LiveView renders `<.traffic_sparkline data={@timeseries} />`
- **THEN** a small area chart renders inline without axes or legends
- **AND** the chart is responsive to container width

### Requirement: Flows Dashboard Homepage
The web-ng UI SHALL provide a dashboard homepage at `/flows` displaying aggregated flow statistics in a widget grid layout. The dashboard MUST show: total bandwidth, active flow count, unique talkers count, top-N talkers, top-N listeners, top-N conversations, top-N applications, top-N protocols, and a traffic-over-time chart.

#### Scenario: Dashboard loads with default time window
- **GIVEN** an authenticated user navigates to `/flows`
- **WHEN** the page loads
- **THEN** the dashboard displays stat cards and top-N tables for the default time window (last 1 hour)
- **AND** data is fetched from the appropriate CAGG or raw hypertable based on the time window

#### Scenario: Time window change refreshes all widgets
- **GIVEN** the dashboard is displaying stats for "Last 1h"
- **WHEN** the user selects "Last 7d" from the time window selector
- **THEN** all stat cards, tables, and charts refresh with data from the 7-day window
- **AND** the SRQL engine auto-selects the 1-hour CAGG for efficiency

#### Scenario: Drill-down from top talker to visualize
- **GIVEN** the dashboard shows "Top 10 Talkers"
- **WHEN** the user clicks on IP `10.1.5.42` in the table
- **THEN** the browser navigates to `/flows/visualize?nf=...` with an SRQL filter for `src_ip:10.1.5.42`
- **AND** the visualize page loads with the filter pre-applied

#### Scenario: Units selector changes display format
- **GIVEN** the dashboard is showing bandwidth in bits/sec
- **WHEN** the user switches to packets/sec
- **THEN** all bandwidth-related stat cards and charts update to display packet rates

### Requirement: Flows Route Structure
The web-ng router SHALL serve the flows dashboard at `/flows` and the visualization page at `/flows/visualize`. Requests to `/flows` with a `nf=` state parameter SHALL redirect to `/flows/visualize` preserving all query parameters.

#### Scenario: Clean navigation to dashboard
- **GIVEN** an authenticated user
- **WHEN** they navigate to `/flows` without query parameters
- **THEN** the flows dashboard homepage loads

#### Scenario: Backward-compatible redirect for visualize URLs
- **GIVEN** a bookmarked URL `/flows?nf=v1-abc123`
- **WHEN** the user navigates to that URL
- **THEN** they are redirected to `/flows/visualize?nf=v1-abc123`
- **AND** the visualize page loads with the preserved state

### Requirement: Flow Unit Formatting
The web-ng UI SHALL provide unit formatting helpers that convert raw byte/packet counts to human-readable strings with SI prefix abbreviation. Supported unit modes: bits/sec, bytes/sec, packets/sec. The helpers MUST be usable from any LiveView or component.

#### Scenario: Large bandwidth formatted with SI prefix
- **WHEN** the formatter receives `1_234_567_890` bytes/sec in bits/sec mode
- **THEN** it returns `"9.88 Gbps"`

#### Scenario: Small packet rate formatted
- **WHEN** the formatter receives `42_300` packets/sec in pps mode
- **THEN** it returns `"42.3 Kpps"`
