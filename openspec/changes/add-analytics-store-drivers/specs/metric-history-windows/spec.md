## ADDED Requirements

### Requirement: Metric history windows preserve query context
Device system metrics, individual interface metric history, and NetFlow pages SHALL offer explicit 1-hour, 6-hour, 24-hour, 7-day, 30-day, and 90-day windows plus a Custom action. Existing default windows SHALL remain unchanged. Selecting a window SHALL retain the current device, interface, metric, and other query filters. Long windows SHALL use coarser chart buckets to bound plotted point counts.

#### Scenario: Extended interface history
- **WHEN** a user selects 90 days on an individual interface history page
- **THEN** the query retains that device, interface index, and selected counter names
- **AND** counter rates use 12-hour chart buckets

#### Scenario: Extended system metrics
- **WHEN** a user selects 30 days on device system metrics
- **THEN** each metric query retains its resolved device identities and metric filters
- **AND** the chart uses 6-hour buckets

#### Scenario: NetFlow window selection
- **WHEN** a user explicitly selects a longer NetFlow window
- **THEN** the existing NetFlow query changes its time range while retaining its filters and presentation state
- **AND** the current NetFlow storage configuration remains unchanged
- **AND** merely opening the page does not trigger a 90-day query

### Requirement: Custom history opens the existing SRQL editor
Custom history SHALL accept an explicitly labeled UTC start and end date. The end SHALL be later than the start. Device and interface history SHALL open the existing metrics SRQL editor with the selected context and absolute time range prefilled. NetFlow SHALL open its existing flow explorer with the current filters and absolute range. Client form values SHALL NOT replace server-owned device or interface query context.

#### Scenario: Custom metric dates
- **WHEN** a user chooses a metric and valid UTC dates
- **THEN** the existing SRQL editor opens with the device and metric filters, absolute time token, and an appropriate chart bucket

#### Scenario: Invalid custom dates
- **WHEN** the dates are invalid or the end is not later than the start
- **THEN** the page displays a validation error and does not navigate or issue the historical query

### Requirement: Chart axes describe the requested window
History charts SHALL preserve the requested time domain even when only a small portion contains samples. They SHALL distinguish the selected window from the first and last available sample, leave missing history empty, and use timezone-aware calendar ticks. Thirty-day windows SHALL use day labels, longer windows SHALL use month labels, and multi-year windows SHALL use year labels with matching tick spacing. Numeric axes SHALL reserve sufficient space for complete formatted values.

#### Scenario: Sparse ninety-day history
- **WHEN** a ninety-day interface query returns two recent buckets
- **THEN** the chart retains the ninety-day domain and requested-range heading
- **AND** the two samples remain at their actual positions near the end of the window
- **AND** no synthetic values fill the missing history

#### Scenario: Calendar-scale flow history
- **WHEN** a user selects thirty days, ninety days, or several years
- **THEN** the axis uses distinct day, month, or year ticks respectively
- **AND** tooltips retain the full sample timestamp

### Requirement: Dashboard windows persist independently
The operations dashboard SHALL provide a time-window selector between the NetFlow map selector and Full Screen, and a selector in place of the Events Over Time range label. Each selection SHALL be validated and saved in its own cookie. Map and event selections SHALL be independent. Without a valid stored preference, the map SHALL default to fifteen minutes and events SHALL default to twenty-four hours. Each panel's data and summary SHALL share one resolved window, and stale requests SHALL NOT replace a later selection.

#### Scenario: Remembered map window
- **WHEN** a user chooses a map window and reloads the operations dashboard
- **THEN** the validated cookie restores that map window
- **AND** map links and totals use the same requested bounds
- **AND** the event chart's independent preference is preserved

#### Scenario: Extended events history
- **WHEN** a user selects a multi-day event window
- **THEN** aggregation uses appropriately sized buckets across the full requested range
- **AND** an hourly row limit does not truncate the chart to two days

### Requirement: Activity failures remain distinguishable from empty history
NetFlow activity panels SHALL distinguish an unsuccessful query from a successful query with no matching samples. A failed protocol or application query SHALL display a panel-specific error and SHALL NOT render fabricated zero-valued history. Application ranking with no matching applications SHALL skip its dependent series query.

#### Scenario: Timed-out application activity
- **WHEN** an application activity query times out
- **THEN** its panel displays a load failure rather than an empty-data message or zero-valued chart
