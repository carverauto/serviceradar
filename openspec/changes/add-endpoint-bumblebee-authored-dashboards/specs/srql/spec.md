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

### Requirement: Security Dashboard Query Support
SRQL and dashboard query support SHALL expose bounded OCSF scan activity, security finding, and DNS Activity fields required by the first-party Security page and Security Findings / Bumblebee Exposure authored dashboard.

#### Scenario: Dashboard queries Bumblebee posture
- **GIVEN** OCSF `Scan Activity` state exists for Bumblebee, Trivy, or endpoint package discovery
- **WHEN** a dashboard panel queries scanner coverage, scan freshness, catalog snapshot, or risk contribution
- **THEN** SRQL SHALL return bounded rows with source type, agent/device identity, activity, status, last scan time, scan duration, catalog identity where available, scanner version, detection count, skipped count, and ServiceRadar producer metadata.

#### Scenario: Dashboard queries OCSF security findings
- **GIVEN** active OCSF security findings exist from Bumblebee, Falco, Trivy, or endpoint package discovery
- **WHEN** a dashboard panel queries finding severity distribution, recent activity, or affected devices
- **THEN** SRQL SHALL return bounded rows with source type, OCSF class, severity, status, catalog ID or rule ID where available, ecosystem/package identity where available, affected resource/device identity, first seen, last seen, and event/device references when available.

#### Scenario: Dashboard queries DNS security activity
- **GIVEN** OCSF DNS Activity exists from PowerDNS or another DNS policy producer
- **WHEN** a Security page or dashboard panel queries DNS security activity
- **THEN** SRQL SHALL return bounded rows with source type, DNS query identity, rule/policy metadata where available, DNS endpoints, activity, status, event time, and ServiceRadar producer metadata.

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
