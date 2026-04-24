## ADDED Requirements

### Requirement: Flows observability pane
The web UI SHALL provide a "Flows" pane that displays flow data from all flow protocols (NetFlow V5, NetFlow V9, IPFIX, sFlow v5) in a unified view with time-series, Sankey, and statistics chart types.

#### Scenario: Flows tab visible in navigation
- **WHEN** a user navigates to the observability section
- **THEN** the UI SHALL display a tab labeled "Flows" (not "NetFlow")
- **AND** the tab SHALL be accessible at the `/flows` route

#### Scenario: sFlow data appears alongside NetFlow
- **WHEN** both NetFlow and sFlow data exist for the selected time window
- **THEN** the Flows pane SHALL display records from both protocols
- **AND** the flow type (NetFlow V5/V9/IPFIX/sFlow v5) SHALL be distinguishable via the `type` field

### Requirement: sFlow collector enrollment
The collector enrollment API SHALL accept `"sflow"` as a valid `collector_type` value and generate appropriate configuration bundles with sFlow-specific defaults.

#### Scenario: Enroll sFlow collector
- **WHEN** a POST request to `/api/admin/collectors` includes `collector_type: "sflow"`
- **THEN** the API SHALL create a collector enrollment with sFlow default config (listen port 6343, subject `flows.raw.sflow`)
- **AND** the generated bundle SHALL include an `sflow.json` config file

#### Scenario: Invalid collector type rejected
- **WHEN** a POST request includes an unsupported `collector_type`
- **THEN** the API SHALL return an error listing valid types including `"sflow"`

## MODIFIED Requirements

### Requirement: Observability panes in the UI
The web UI SHALL provide separate panes for logs, events, alerts, and flows with navigation between related records.

#### Scenario: Event view links to source log and alert
- **GIVEN** a user viewing an event
- **WHEN** the event has related log or alert records
- **THEN** the UI SHALL provide navigation to those records

#### Scenario: Flows pane accessible at /flows
- **WHEN** a user navigates to `/flows`
- **THEN** the UI SHALL display the Flows visualization pane
- **AND** the pane SHALL support all existing visualization modes (time-series, Sankey, statistics)

#### Scenario: Legacy /netflow route redirects
- **WHEN** a user navigates to `/netflow` or `/settings/netflows`
- **THEN** the system SHALL issue an HTTP 301 redirect to `/flows` or `/settings/flows` respectively
- **AND** query parameters SHALL be preserved in the redirect

#### Scenario: Flows settings accessible at /settings/flows
- **WHEN** a user navigates to `/settings/flows`
- **THEN** the UI SHALL display the flow settings page (directionality, enrichment, app rules)
- **AND** settings SHALL apply to all flow types (NetFlow and sFlow)

#### Scenario: SRQL catalog lists Flows
- **WHEN** the SRQL catalog is queried for available data sources
- **THEN** the catalog SHALL include an entry with label "Flows" and route "/flows"
