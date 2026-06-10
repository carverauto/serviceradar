## ADDED Requirements

### Requirement: OCSF Security Producer Mapping
Security add-ons and scanner integrations SHALL normalize scanner lifecycle and security outcome data into OCSF `1.9.0-dev` events before those events are stored, queried, or rendered as first-class security signals.

#### Scenario: Scanner lifecycle emits Scan Activity
- **GIVEN** Bumblebee, Trivy, or endpoint package discovery starts, completes, fails, pauses, resumes, or otherwise changes scanner execution state
- **WHEN** the platform receives the scanner lifecycle update
- **THEN** it SHALL create or ingest an OCSF `Scan Activity` event with `class_uid: 6007`, `category_uid: 6`, `metadata.version: "1.9.0-dev"`, the correct `activity_id`, `type_uid`, `scan` object, status, timestamps, duration where available, item counts where available, and ServiceRadar producer metadata.

#### Scenario: Scanner outcomes emit OCSF findings
- **GIVEN** Bumblebee, Falco, Trivy, or endpoint package discovery reports a security outcome
- **WHEN** the platform normalizes the outcome
- **THEN** it SHALL emit the most specific OCSF `Findings` class available in OCSF `1.9.0-dev`
- **AND** it SHALL NOT expose a source-specific public finding schema when `Vulnerability Finding`, `Compliance Finding`, `Detection Finding`, or `Application Security Posture Finding` fits the outcome.

#### Scenario: Falco maps runtime alerts to Detection Finding
- **GIVEN** Falco reports a runtime security alert
- **WHEN** the alert is normalized
- **THEN** the platform SHALL emit an OCSF `Detection Finding` event with `class_uid: 2004`, `category_uid: 2`, `metadata.version: "1.9.0-dev"`, finding identity, severity, affected resource or device, evidence, and ServiceRadar producer metadata.

#### Scenario: Trivy maps scans and vulnerabilities separately
- **GIVEN** Trivy completes a scan and reports one or more vulnerabilities or policy issues
- **WHEN** the results are normalized
- **THEN** the scan execution SHALL be represented by OCSF `Scan Activity`
- **AND** CVE-backed vulnerabilities SHALL be represented by OCSF `Vulnerability Finding`
- **AND** policy or benchmark violations SHALL be represented by OCSF `Compliance Finding`
- **AND** application or dependency posture issues SHALL be represented by OCSF `Application Security Posture Finding`.

#### Scenario: Endpoint package discovery remains inventory-first
- **GIVEN** endpoint package discovery reports installed package inventory without a vulnerability, compliance, posture, or detection outcome
- **WHEN** the data is normalized
- **THEN** the platform SHALL preserve it as inventory data rather than inventing a security finding
- **AND** it MAY emit OCSF `Scan Activity` for the collector execution lifecycle
- **AND** it SHALL emit an OCSF Finding only when enrichment identifies a real vulnerability, exposure, compliance, posture, or detection condition.

#### Scenario: Security signals preserve inventory device correlation
- **GIVEN** Bumblebee, Falco, Trivy, or endpoint package discovery emits OCSF Scan Activity or Finding events
- **WHEN** the producer knows or can infer inventory identity from device UID, agent ID, host/node name, or host IP
- **THEN** the event SHALL preserve those values in `metadata.service_radar` and the OCSF `device` object using the inventory device as the primary device identity
- **AND** pod, container, package, rule, and scanner-specific identities SHALL remain available as resources, observables, evidence, or source metadata without replacing the inventory device identity.

### Requirement: Security Signals Query Surface
SRQL and dashboard query support SHALL expose bounded query surfaces for OCSF security findings, OCSF scan activity, and OCSF DNS Activity events used by the Security page and first-party security dashboards.

#### Scenario: Query active security findings
- **GIVEN** OCSF security finding events exist
- **WHEN** a Security page or dashboard panel queries active findings
- **THEN** SRQL SHALL return bounded rows with finding class, source type, severity, status, affected device/resource, finding identity, first seen, last seen, and ServiceRadar producer metadata.

#### Scenario: Query scanner activity
- **GIVEN** OCSF `Scan Activity` events exist
- **WHEN** a Security page or dashboard panel queries scanner execution state
- **THEN** SRQL SHALL return bounded rows with scanner source, activity, status, started/completed timestamps, duration, total scanned count, detection count, skipped count, agent/device identity, and ServiceRadar producer metadata.

#### Scenario: Query DNS security activity
- **GIVEN** OCSF DNS Activity events exist
- **WHEN** a Security page or dashboard panel queries DNS policy activity
- **THEN** SRQL SHALL return bounded rows with DNS source, activity, status, queried hostname, source and destination endpoints, policy/rule context where available, event time, and ServiceRadar producer metadata.

#### Scenario: Security query bounds are enforced
- **GIVEN** a Security page or dashboard query omits an explicit limit or time bound
- **WHEN** the query executes
- **THEN** the SRQL or dashboard runtime SHALL apply configured bounds
- **AND** it SHALL avoid broad unbounded aggregate scans from LiveView render paths.
