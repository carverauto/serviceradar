## MODIFIED Requirements

### Requirement: Favorited Interface Metrics Visualization

The device details view SHALL display metrics visualizations for favorited interfaces with metrics collection enabled, positioned above the interfaces table. Each traffic, inbound-packet and outbound-packet chart SHALL occupy its own full-width row, stacked vertically with interface identity, readable axes and legends at desktop and narrow widths. Favorites, selected windows, loading and real-gap behavior SHALL be preserved.

#### Scenario: Display metrics for favorited interfaces
- **GIVEN** a device with interfaces that are favorited AND have metrics collection enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** a metrics visualization section appears above the interfaces table
- **AND** displays graphs for each favorited interface's metrics

#### Scenario: Auto-select visualization type
- **GIVEN** a favorited interface with counter-type metrics (e.g., bytes in/out)
- **WHEN** the visualization renders
- **THEN** a line or area chart is displayed showing the metric over time

#### Scenario: Gauge metric visualization
- **GIVEN** a favorited interface with gauge-type metrics (e.g., utilization percentage)
- **WHEN** the visualization renders
- **THEN** a gauge or percentage chart is displayed

#### Scenario: No favorited interfaces
- **GIVEN** a device with no favorited interfaces with metrics enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** the metrics visualization section is not displayed
- **OR** shows an empty state message

#### Scenario: Multiple favorited interfaces at narrow width
- **WHEN** multiple favorited interfaces render traffic and packet metrics on a narrow viewport
- **THEN** their charts stack as full-width rows rather than nested side-by-side chart grids
- **AND** every chart retains readable identity, axes and legend without page overflow

## ADDED Requirements

### Requirement: Consistent metric history windows
The UI SHALL support 1h, 6h, 24h, 7d, 30d, 90d and custom metric windows for applicable sysmon, interface and NetFlow views, preserving resolved query bounds separately from observed sample bounds.

#### Scenario: Sparse long-window data
- **WHEN** a user selects 90 days but samples cover only a few hours
- **THEN** both query and chart retain the requested 90-day bounds
- **AND** calendar-aware labels use the user timezone with a UTC fallback
- **AND** regular polling samples connect while genuine missing-data gaps remain visible

#### Scenario: Window changes during a pending request
- **WHEN** a newer window is selected before an older request completes
- **THEN** the older task is canceled or invalidated
- **AND** its result cannot overwrite the newer selection

### Requirement: Independent remembered dashboard windows
The home dashboard SHALL persist NetFlow-map and Events Over Time window preferences independently, propagate the map window into Full Screen, and retain authorization context on every query.

#### Scenario: Preferences survive reload independently
- **WHEN** the operator changes the map window and reloads
- **THEN** the map retains that window and the events window retains its separate value
- **AND** malformed or unsupported cookie values use a valid default

#### Scenario: Authenticated panel request
- **WHEN** a panel refreshes or opens Full Screen
- **THEN** its request retains the actor and authorized data scope
- **AND** query failure is displayed as an error rather than an empty successful result or unconfigured collector

### Requirement: Status-authoritative availability and stable pending charts
The UI SHALL derive availability from explicit status gauges, preserve selected-observer authority including failures, choose an available observer for fallback intervals when possible, and keep missing history unknown.

#### Scenario: Canonical observer fails while another succeeds
- **WHEN** the selected canonical observer reports failure
- **THEN** the canonical view reports that failure rather than substituting another observer or latency
- **AND** fallback selection may use an available observer for that interval

#### Scenario: Refresh and source change
- **WHEN** a periodic refresh occurs while ICMP or interface chart work is pending
- **THEN** the pending work survives while its request identity remains applicable
- **AND** pagination or observer changes invalidate results that no longer match the current request

### Requirement: Focused device list and NetFlow loading
The UI SHALL omit the Tags column only from the device list and SHALL load NetFlow panels according to the active view while retaining explicit query errors.

#### Scenario: Inactive NetFlow panel
- **WHEN** a NetFlow view does not display a panel
- **THEN** that panel's query is not required for the active view to complete

#### Scenario: Tags remain usable outside the list column
- **WHEN** the device list renders with or without composite verdicts
- **THEN** header and body column counts agree without the Tags column
- **AND** tag management and other tag displays remain available
