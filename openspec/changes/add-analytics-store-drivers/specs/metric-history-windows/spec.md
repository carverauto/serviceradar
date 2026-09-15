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
