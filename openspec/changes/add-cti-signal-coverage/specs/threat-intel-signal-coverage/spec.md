## ADDED Requirements

### Requirement: Canonical CTI Observable Inventory
The system SHALL store imported CTI observables across all supported observable types so operators can distinguish imported intelligence from locally observed matches.

#### Scenario: Import non-IP observable
- **GIVEN** a CTI provider returns a domain, URL, file hash, CVE, package, TLS fingerprint, malware, or campaign observable
- **WHEN** ServiceRadar ingests the provider page
- **THEN** the observable SHALL be stored in the canonical CTI observable inventory with provider, source, type, value, confidence, severity, validity, source object, and metadata
- **AND** the observable SHALL NOT be discarded solely because it is not NetFlow-matchable

#### Scenario: Display imported versus observed status
- **GIVEN** an imported observable has no local telemetry match
- **WHEN** an operator views the Threat Intel UI
- **THEN** the UI SHALL show the observable as imported without presenting it as a confirmed local finding

### Requirement: Source-Specific CTI Match Projections
The system SHALL match CTI observables through source-specific indexed projections instead of joining every telemetry table directly against the full CTI inventory.

#### Scenario: Matcher evaluates observed values
- **GIVEN** a matcher supports a telemetry source and observable type
- **WHEN** the matcher runs for a bounded time window or high-water range
- **THEN** it SHALL compare normalized observed values with the relevant CTI projection
- **AND** it SHALL write deduplicated sightings or findings with source evidence

#### Scenario: Unsupported observable type remains queryable
- **GIVEN** an imported observable type has no implemented matcher
- **WHEN** matching jobs run
- **THEN** the observable SHALL remain queryable in inventory
- **AND** the run SHALL record that the type is not match-supported rather than failing

### Requirement: DNS Telemetry For Domain CTI
The system SHALL support DNS telemetry collection so domain and hostname CTI observables can be matched against local DNS behavior.

#### Scenario: Managed DNS resolver records query
- **GIVEN** the ServiceRadar-managed DNS forwarding resolver is enabled
- **WHEN** a client performs a DNS lookup through it
- **THEN** ServiceRadar SHALL record the client identity, query name, normalized query name, answers, response code, resolver identity, and timestamp

#### Scenario: Existing DNS server integration records query
- **GIVEN** a deployment uses an existing DNS server
- **WHEN** a configured log, syslog, plugin, or streaming integration receives DNS events
- **THEN** ServiceRadar SHALL normalize the events into the same DNS observation model used by the managed resolver

#### Scenario: Domain CTI matches DNS history
- **GIVEN** an imported domain or hostname observable
- **AND** DNS observations contain a matching query or answer
- **WHEN** the DNS CTI matcher runs
- **THEN** ServiceRadar SHALL create a finding that links the observable, client asset, DNS event window, source provider, and evidence count

### Requirement: Envoy WAF And HTTP/TLS CTI Telemetry
The system SHALL support opt-in Envoy-based HTTP, TLS, and WAF telemetry so URL, hostname, SNI, TLS fingerprint, and web policy observables can be matched.

#### Scenario: Envoy records HTTP request metadata
- **GIVEN** Envoy telemetry is enabled for a ServiceRadar-managed ingress or gateway path
- **WHEN** Envoy observes an HTTP request
- **THEN** ServiceRadar SHALL ingest authority, URL or path, method, status, client and server addresses, user agent when configured, TLS/SNI metadata when available, and timestamp

#### Scenario: WAF decision is recorded
- **GIVEN** WAF observation or enforcement is enabled for an Envoy path
- **WHEN** a request is evaluated by the WAF integration
- **THEN** ServiceRadar SHALL record the policy decision, action, rule identifiers, severity, and request context needed to explain the event

#### Scenario: URL CTI matches WAF or HTTP event
- **GIVEN** an imported URL, domain, hostname, or TLS fingerprint observable
- **AND** HTTP/TLS/WAF telemetry contains a matching observed value
- **WHEN** the HTTP/TLS/WAF matcher runs
- **THEN** ServiceRadar SHALL create a finding that links the observable, request event, related asset, source provider, and evidence count

### Requirement: Agent SBOM And Endpoint CTI Matching
The system SHALL collect endpoint software and SBOM inventory from agents so file hash, package, product, and CVE observables can be matched against assets.

#### Scenario: Agent submits SBOM
- **GIVEN** SBOM collection is enabled for an agent
- **WHEN** the agent scans installed software or receives a configured SBOM source
- **THEN** ServiceRadar SHALL store a durable SBOM artifact and normalized package/component rows linked to the asset

#### Scenario: File hash CTI matches endpoint inventory
- **GIVEN** an imported file hash observable
- **AND** endpoint inventory contains a matching executable, process, package artifact, or file metadata row
- **WHEN** the endpoint CTI matcher runs
- **THEN** ServiceRadar SHALL create a finding linked to the asset, observed file metadata, source observable, and evidence time

#### Scenario: CVE CTI matches asset package inventory
- **GIVEN** an imported CVE or vulnerable product observable
- **AND** an asset SBOM or package inventory contains an affected component
- **WHEN** the vulnerability matcher runs
- **THEN** ServiceRadar SHALL create or update an affected-asset finding with package, version, CVE, source provider, severity, and evidence context

### Requirement: Edge SIEM CTI Sightings
The system SHALL allow assigned edge Wasm plugins to import SIEM or customer-local security sightings into the same CTI sighting contract.

#### Scenario: SIEM plugin emits sighting
- **GIVEN** a SIEM collector plugin is assigned to an agent with approved network access and credentials
- **WHEN** the plugin polls or receives security events
- **THEN** it SHALL emit normalized sightings with source system, observed value, observable type, asset or network context, timestamp, confidence, severity, and redacted metadata

#### Scenario: Collector assignment avoids duplicate polling
- **GIVEN** a SIEM or CTI collector should run from only one edge location
- **WHEN** an operator configures the collector
- **THEN** ServiceRadar SHALL support assigning it to a single selected agent or bounded agent set
- **AND** duplicate scheduled polling for the same source SHALL be prevented

### Requirement: CTI SRQL And Alerting
The system SHALL expose CTI inventory, sightings, and findings through SRQL and alerting primitives.

#### Scenario: Operator queries CTI matches
- **GIVEN** CTI findings exist for NetFlow, DNS, HTTP/WAF, endpoint, or vulnerability sources
- **WHEN** an operator runs an SRQL query using CTI fields
- **THEN** SRQL SHALL return matching records with observable type, value, source, severity, confidence, asset context, and evidence count where available

#### Scenario: High-confidence sighting creates alert
- **GIVEN** a CTI sighting meets configured severity, confidence, source, and asset criteria
- **WHEN** the alert evaluator processes the sighting
- **THEN** ServiceRadar SHALL create or update an alert without duplicating repeated evidence in the same configured window

### Requirement: CTI Visibility Across Dashboard, Topology, And Assets
The system SHALL surface CTI context where operators already triage traffic and assets.

#### Scenario: Dashboard shows coverage by signal source
- **GIVEN** CTI inventory and sightings exist
- **WHEN** an operator opens the dashboard
- **THEN** the dashboard SHALL show imported observable counts, confirmed sighting counts, and coverage by NetFlow, DNS, HTTP/WAF, endpoint/SBOM, vulnerability, and SIEM source

#### Scenario: Topology shows hostile traffic
- **GIVEN** CTI findings are linked to flows, DNS clients, HTTP requests, or affected assets
- **WHEN** an operator opens a topology or NetFlow map view
- **THEN** ServiceRadar SHALL visually distinguish traffic or assets with CTI findings and allow drilldown to evidence

#### Scenario: Asset detail shows CTI evidence
- **GIVEN** an asset has CTI-linked flows, DNS observations, endpoint hashes, packages, CVEs, or SIEM sightings
- **WHEN** an operator opens the asset detail page
- **THEN** ServiceRadar SHALL show the relevant CTI evidence grouped by source and observable type

### Requirement: CTI Telemetry Security And Retention
The system SHALL protect CTI credentials and sensitive telemetry while allowing operators to configure retention and redaction.

#### Scenario: Secret is saved for CTI telemetry source
- **GIVEN** an operator saves credentials for a CTI provider, DNS integration, WAF integration, or SIEM connector
- **WHEN** the setting is persisted
- **THEN** the secret SHALL be encrypted at rest
- **AND** later reads SHALL only expose whether the secret is present

#### Scenario: Sensitive telemetry retention expires
- **GIVEN** DNS, URL, WAF, endpoint, SIEM, or raw artifact retention is configured
- **WHEN** data exceeds its retention window
- **THEN** ServiceRadar SHALL remove or compact the sensitive telemetry according to that policy while preserving allowed aggregate findings

#### Scenario: Egress policy blocks unapproved endpoint
- **GIVEN** a CTI, DNS, WAF, or SIEM collector attempts to reach an endpoint outside the approved egress policy
- **WHEN** the network request is evaluated
- **THEN** ServiceRadar SHALL deny the request and record a redacted operational error
