## ADDED Requirements

### Requirement: Endpoint Inventory Dashboard Query Support
SRQL and dashboard query support SHALL expose bounded endpoint inventory fields and aggregates required by the first-party Endpoint Inventory authored dashboard.

#### Scenario: Dashboard queries endpoint inventory freshness
- **GIVEN** endpoint inventory scan state exists
- **WHEN** a dashboard panel queries endpoint inventory freshness, coverage, or failure state
- **THEN** SRQL SHALL return bounded rows with agent/device identity, freshness verdict, last scan time, scan status, and bounded status/error detail.

#### Scenario: Dashboard queries endpoint package rollups
- **GIVEN** endpoint inventory package state exists
- **WHEN** a dashboard panel queries package count, source distribution, top package coordinates, or risk summary rollups
- **THEN** SRQL SHALL answer from maintained current-state, indexed, or aggregate-backed surfaces
- **AND** it SHALL NOT require a broad unbounded aggregate scan from the LiveView render path.

### Requirement: Bumblebee Dashboard Query Support
SRQL and dashboard query support SHALL expose bounded Bumblebee posture and finding fields required by the first-party Bumblebee Exposure authored dashboard.

#### Scenario: Dashboard queries Bumblebee posture
- **GIVEN** Bumblebee posture state exists
- **WHEN** a dashboard panel queries scanner coverage, scan freshness, catalog snapshot, or risk contribution
- **THEN** SRQL SHALL return bounded rows with agent/device identity, coverage state, last scan time, catalog identity, scanner version, active finding count, highest severity, and risk contribution.

#### Scenario: Dashboard queries Bumblebee findings
- **GIVEN** active Bumblebee findings exist
- **WHEN** a dashboard panel queries finding severity distribution, recent activity, or affected devices
- **THEN** SRQL SHALL return bounded rows with severity, status, catalog ID, ecosystem, package identity, device identity, first seen, last seen, and event/device references when available.

### Requirement: Dashboard Queries Preserve Authorization And Bounds
SRQL-backed dashboard panels for product-authored dashboards SHALL preserve the same authorization, row-limit, and timeout bounds as user-authored dashboard panels.

#### Scenario: Unauthorized data is not returned
- **GIVEN** a user can view dashboards but lacks access to a protected inventory or security field
- **WHEN** a product-authored dashboard panel executes
- **THEN** SRQL SHALL omit or redact unauthorized fields according to the existing authorization model.

#### Scenario: Panel query is bounded
- **GIVEN** a product-authored dashboard panel omits an explicit limit or time bound
- **WHEN** the panel query executes
- **THEN** the dashboard runtime or SRQL layer SHALL apply configured bounds
- **AND** the panel SHALL report bounded or partial results when applicable.

