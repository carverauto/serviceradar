## ADDED Requirements

### Requirement: Dedicated NetFlow Visualize Page
The system SHALL provide a dedicated `/netflow` route in `web-ng` for NetFlow analytics with a two-panel layout: a left options panel and a right visualization panel.

#### Scenario: User navigates to the NetFlow Visualize page
- **WHEN** a user navigates to `/netflow`
- **THEN** the page renders the left options panel and right visualization surface

### Requirement: Legacy Entry Points Redirect
The system SHALL preserve NetFlow bookmarks by redirecting legacy entry points to `/netflow` while preserving the SRQL query parameter `q` when present.

#### Scenario: Observability netflows tab redirects to /netflow
- **GIVEN** a user opens `/observability?tab=netflows&q=in:flows+time:last_1h`
- **WHEN** the route is handled
- **THEN** the user is redirected to `/netflow?q=in:flows+time:last_1h`

#### Scenario: /netflows redirects to /netflow
- **WHEN** a user opens `/netflows?q=in:flows+time:last_1h`
- **THEN** the user is redirected to `/netflow?q=in:flows+time:last_1h`

### Requirement: Shareable URL State For Visualize Options
The system SHALL encode Visualize page options into the URL as a versioned, compressed payload.

#### Scenario: URL state round-trip
- **GIVEN** the URL contains `nf=v1-<payload>`
- **WHEN** the Visualize page loads
- **THEN** the Visualize page uses the decoded options to render
- **AND** encoding the options produces the same `nf` value (deterministic)
