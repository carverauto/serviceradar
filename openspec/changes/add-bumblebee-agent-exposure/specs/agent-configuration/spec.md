## ADDED Requirements
### Requirement: Bumblebee Scanner Configuration
The system SHALL support an opt-in Bumblebee scanner configuration delivered through the existing agent configuration flow. The configuration SHALL include enablement, scan profile, root discovery mode, explicit roots, ecosystem filters, max duration, cadence, findings-only behavior, and the exposure catalog snapshot identifier. The main `serviceradar-agent` SHALL remain non-root; full-system scans SHALL be performed by a dedicated root-owned scanner service.

#### Scenario: Agent starts with Bumblebee disabled
- **GIVEN** an agent receives configuration without Bumblebee enabled
- **WHEN** the agent starts or refreshes configuration
- **THEN** no Bumblebee scan is scheduled or executed
- **AND** no package inventory or finding records are emitted

#### Scenario: Agent receives enabled Bumblebee configuration
- **GIVEN** an agent receives Bumblebee configuration with `enabled` set to true
- **AND** the configuration includes a supported profile and catalog snapshot
- **WHEN** the agent applies the configuration
- **THEN** it writes or refreshes scanner-service configuration for bounded one-shot scans according to the configured cadence
- **AND** the scanner-service configuration includes the configured profile, roots, ecosystems, max duration, and catalog snapshot

#### Scenario: Agent receives catalog assignment
- **GIVEN** core has promoted a versioned Bumblebee catalog snapshot
- **WHEN** an agent receives Bumblebee configuration
- **THEN** the configuration SHALL include immutable catalog snapshot ID, datasvc object key, content SHA256, byte size, and catalog version
- **AND** the agent SHALL stage the catalog from the ServiceRadar control plane instead of fetching upstream catalog URLs directly
- **AND** the agent SHALL activate the staged catalog only after the content hash matches the assignment

#### Scenario: Unsafe or unsupported scan roots are rejected
- **GIVEN** Bumblebee configuration contains roots that violate profile rules or local safety policy
- **WHEN** the agent or scanner service validates the configuration
- **THEN** the system SHALL reject those roots for the scan
- **AND** report bounded configuration diagnostics instead of running an unbounded scan

#### Scenario: All-users root discovery scans every eligible home
- **GIVEN** Bumblebee configuration selects all-users root discovery
- **WHEN** the root-owned scanner service resolves scan roots on a host
- **THEN** it SHALL enumerate eligible local user home directories from OS account data
- **AND** include `/root` when readable and enabled by policy
- **AND** pass the resolved roots explicitly to Bumblebee rather than relying on the scanner process user's `~`

#### Scenario: Current-user discovery remains available for developer runs
- **GIVEN** Bumblebee configuration selects current-user root discovery
- **WHEN** the agent resolves scan roots
- **THEN** it SHALL scan only roots derived from the user context running the scanner plus any explicit configured roots
- **AND** report the selected discovery mode in scan diagnostics

### Requirement: Bumblebee Root-Owned Scanner Service
The system SHALL run full-system Bumblebee scans through a dedicated root-owned scanner service while keeping `serviceradar-agent` non-root. The scanner service SHALL use fixed configuration, bounded arguments, scrubbed environment variables, read-only scanner behavior, output size limits, and a sanitized spool contract consumed by the agent.

#### Scenario: Base agent package does not install scanner helper
- **GIVEN** an operator installs the standard `serviceradar-agent` RPM or deb package
- **WHEN** the package post-install script runs
- **THEN** it SHALL NOT install, enable, or start `serviceradar-bumblebee-scan.service` or `serviceradar-bumblebee-scan.timer`
- **AND** it SHALL NOT create root-owned Bumblebee state directories unless the optional native capability bundle is installed

#### Scenario: Optional native capability bundle installs scanner helper
- **GIVEN** an operator enables the Bumblebee native capability through Edge Ops feature-set deployment
- **WHEN** the add-on is installed on a Linux host
- **THEN** it SHALL install the root-owned scanner helper, scanner config, systemd service, systemd timer, and spool directory permissions
- **AND** the existing non-root `serviceradar-agent` SHALL report the sanitized spool without requiring a different agent package
- **AND** the add-on SHALL NOT enable or start the timer until Edge Ops or a local operator explicitly activates the capability

#### Scenario: Non-root agent ingests sanitized output
- **GIVEN** the root-owned scanner service completes a Bumblebee scan
- **WHEN** it writes findings, scan summary, and coverage metadata to the spool path
- **THEN** the non-root agent SHALL read the sanitized spool output
- **AND** the agent SHALL NOT require permission to read arbitrary user home directories

#### Scenario: Scanner service reports partial coverage
- **GIVEN** the scanner service cannot read one or more configured roots
- **WHEN** it completes the scan
- **THEN** the spool output SHALL include attempted roots, scanned roots, skipped roots, and bounded skip reasons
- **AND** the control plane SHALL distinguish partial coverage from a clean scan with no findings

#### Scenario: Scanner service cadence is externally auditable
- **GIVEN** Bumblebee scanning is enabled on a Linux host
- **WHEN** the package is installed
- **THEN** scans SHALL be scheduled through a named systemd timer or equivalent platform scheduler
- **AND** operators SHALL be able to inspect, disable, or trigger the scanner service without granting root privileges to the main agent process

### Requirement: Bumblebee Local Override And Cache
The `serviceradar-agent` SHALL support local filesystem Bumblebee configuration overrides and cache the last-known-good Bumblebee configuration and catalog snapshot for offline operation.

#### Scenario: Local Bumblebee override exists
- **GIVEN** a valid local Bumblebee configuration file exists under the ServiceRadar configuration directory
- **WHEN** the agent resolves Bumblebee configuration
- **THEN** the local override takes precedence over remotely delivered Bumblebee settings
- **AND** the agent logs that local Bumblebee configuration is in use

#### Scenario: Cached catalog is used when control plane is unreachable
- **GIVEN** an agent has a cached Bumblebee configuration and catalog snapshot
- **AND** the control plane is unreachable during configuration refresh
- **WHEN** the next Bumblebee scan is due
- **THEN** the agent MAY run using the cached snapshot
- **AND** the scan report SHALL include the cached snapshot identifier

### Requirement: Bumblebee Catalog Delivery
The system SHALL distribute promoted Bumblebee catalog snapshots to agents through ServiceRadar-managed delivery channels. Large catalog artifacts SHALL be staged in datasvc-backed object storage and online agents MAY be nudged through `AgentCommandBus` via agent-gateway to fetch or activate a specific snapshot.

#### Scenario: Online agent is nudged after catalog promotion
- **GIVEN** a new catalog snapshot has been promoted and assigned to an online agent
- **WHEN** core dispatches a catalog update command
- **THEN** agent-gateway SHALL deliver a bounded command/config notification to the agent
- **AND** the agent SHALL fetch the immutable artifact from ServiceRadar object storage using the assigned object key
- **AND** the agent SHALL report activation or failure with bounded diagnostics

#### Scenario: Offline agent catches up on next config poll
- **GIVEN** a new catalog snapshot has been promoted while an agent is offline
- **WHEN** the agent reconnects or polls configuration
- **THEN** it SHALL receive the current catalog assignment
- **AND** stage and verify the assigned artifact before using it for scans

### Requirement: Bumblebee Scan Reporting
The `serviceradar-agent` SHALL report Bumblebee scan summaries, bounded diagnostics, and exposure findings through the existing agent-to-gateway push path with replay-safe identifiers.

#### Scenario: Finding records are reported
- **GIVEN** a Bumblebee scan emits finding records from an exposure catalog match
- **WHEN** the agent parses the scanner NDJSON output
- **THEN** each accepted finding SHALL be reported with scanner version, run ID, catalog ID, catalog snapshot ID, severity, ecosystem, package identity, evidence, confidence, and source provenance
- **AND** full package inventory records SHALL NOT be reported unless explicitly enabled by a future approved change

#### Scenario: Scan summary marks run complete
- **GIVEN** a Bumblebee scan exits successfully
- **WHEN** the scan emits a scan summary record
- **THEN** the agent SHALL report the summary as the completion signal for that run
- **AND** the control plane SHALL use the summary to determine whether the run can update current exposure state
