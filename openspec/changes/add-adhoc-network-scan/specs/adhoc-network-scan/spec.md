# adhoc-network-scan

## ADDED Requirements

### Requirement: Initiate an ad-hoc scan against a target list
The system SHALL let an authorized user start an ad-hoc network scan by
supplying a list of target IP addresses, selecting one or more scan modes,
and choosing the agent that egresses the scan.

#### Scenario: Start a scan from pasted targets
- **WHEN** a user with `scans.execute` submits a target list, at least one
  mode (`icmp`, `tcp`, or `mtr`), and an online agent
- **THEN** the system SHALL create a `ScanRun` record capturing the agent,
  modes, ports, normalized targets, and options, and dispatch the work to
  the chosen agent

#### Scenario: TCP mode requires ports
- **WHEN** a scan request includes mode `tcp` but no ports
- **THEN** the system SHALL reject the request with a validation error and
  create no `ScanRun`

#### Scenario: Agent must be online and capable
- **WHEN** the chosen agent is offline or lacks the required scan capability
- **THEN** the system SHALL reject the request and report why, creating no
  dispatch

### Requirement: Target list ingestion
The system SHALL accept targets by paste, by drag-and-drop, and by
uploading a `.csv` or `.txt` file, and SHALL parse, validate, and de-duplicate
them before dispatch.

#### Scenario: Upload a CSV of targets
- **WHEN** a user drops or uploads a `.csv`/`.txt` file of IP addresses
- **THEN** the system SHALL parse the addresses, drop duplicates, flag
  malformed entries for the user to correct, and use the valid set as the
  scan targets

#### Scenario: Malformed entries are surfaced, not silently dropped
- **WHEN** the target list contains entries that are not valid IPs or CIDRs
- **THEN** the system SHALL show which entries were rejected and why before
  the user confirms the scan

### Requirement: Reuse the on-demand agent command bus
Ad-hoc scans SHALL be dispatched over the existing addressed-to-one-agent
command bus. ICMP/TCP SHALL use a new inline-target-list command; MTR SHALL
reuse the existing bulk-MTR command, correlated to the same `ScanRun`.

#### Scenario: ICMP/TCP dispatch
- **WHEN** a `ScanRun` requests `icmp` and/or `tcp`
- **THEN** the system SHALL dispatch a `scan.run_adhoc` command carrying the
  inline target and port list to the chosen agent, subject to TTL and
  per-agent concurrency limits

#### Scenario: MTR dispatch reuses the existing command
- **WHEN** a `ScanRun` requests `mtr`
- **THEN** the system SHALL dispatch the existing bulk-MTR command tagged
  with the `scan_run_id`, without introducing a second MTR implementation

#### Scenario: Live progress during a large scan
- **WHEN** an agent is running a scan over a large target list
- **THEN** the agent SHALL stream progress updates over the command channel
  so the UI can show completion as targets finish

### Requirement: Durable results via JetStream
Scan results SHALL be persisted by emitting them onto NATS JetStream and
writing them to the database through the event-writer consumer pipeline,
never by a direct database write from the agent or gateway. The interactive
command channel SHALL be used only for live progress, not as the system of
record.

#### Scenario: Results land in the durable store
- **WHEN** an agent completes ICMP/TCP checks for a `ScanRun`
- **THEN** the agent SHALL emit an `adhoc-scan-metrics` batch onto the
  metrics JetStream stream, and an event-writer processor SHALL persist per
  target/port rows (availability, response time, port state) into the
  `adhoc_scan_results` hypertable keyed by `scan_run_id`

#### Scenario: Results table has retention
- **WHEN** the `adhoc_scan_results` hypertable is created
- **THEN** a retention policy SHALL drop rows older than the configured
  window (default 30 days)

#### Scenario: MTR results correlate to the run
- **WHEN** a `ScanRun` included `mtr`
- **THEN** its MTR traces SHALL be retrievable for that `scan_run_id` and be
  joinable with the ICMP/TCP results for display and export

### Requirement: View scan runs and results
Authorized users SHALL be able to view a scan run's status and its results
in a table.

#### Scenario: Watch a run to completion
- **WHEN** a user with `scans.read` opens a running scan
- **THEN** the UI SHALL show per-target/per-port results as they arrive and
  reflect the run's terminal status when finished

### Requirement: Export scan results
Authorized users SHALL be able to export a scan run's results as CSV and as
XLSX.

#### Scenario: CSV export
- **WHEN** a user with `scans.export` exports a completed run as CSV
- **THEN** the system SHALL stream a CSV containing the joined ICMP/TCP and
  MTR results for that run

#### Scenario: XLSX export
- **WHEN** a user with `scans.export` exports a completed run as XLSX
- **THEN** the system SHALL return an XLSX workbook of the same result set

### Requirement: Inventory-scoping guardrail
The system SHALL provide an admin-managed setting that, when enabled,
forbids scanning IP addresses that are not already in the ServiceRadar
device inventory.

#### Scenario: Blocked when a target is not in inventory
- **WHEN** the inventory-scoping setting is enabled and a scan request
  includes an IP with no matching inventory device
- **THEN** the system SHALL reject the scan and return the offending IPs
  rather than dispatching a partial scan

#### Scenario: Disabled setting allows arbitrary targets
- **WHEN** the inventory-scoping setting is disabled
- **THEN** the system SHALL allow any well-formed target list

#### Scenario: Only managers can change the setting
- **WHEN** a user without `scans.manage` attempts to toggle the setting
- **THEN** the system SHALL refuse the change

### Requirement: Add missing devices to inventory
When the inventory-scoping guardrail blocks a scan, the system SHALL let a
user with device-create permission add the missing IPs to inventory,
individually and in bulk, and then proceed.

#### Scenario: Bulk-add missing devices
- **WHEN** a scan is blocked by hundreds of not-in-inventory IPs and the
  user has `devices.import`
- **THEN** the system SHALL let the user add all missing IPs to inventory in
  one bulk action (reusing the existing device-creation path) and re-run the
  scan

#### Scenario: Add-missing requires device permission
- **WHEN** a user without `devices.create`/`devices.import` tries to add
  missing devices
- **THEN** the system SHALL refuse and leave inventory unchanged

### Requirement: RBAC coverage
The ad-hoc scan surface SHALL be governed by dedicated permissions
(`scans.execute`, `scans.read`, `scans.export`, `scans.manage`) enforced in
the LiveView, the REST API, and the underlying resource policy.

#### Scenario: Execute requires permission
- **WHEN** a user lacking `scans.execute` attempts to start a scan through
  any surface (UI or API)
- **THEN** the system SHALL deny the request

#### Scenario: Read/export gating
- **WHEN** a user has `scans.read` but not `scans.export`
- **THEN** the system SHALL allow viewing results but deny export

### Requirement: REST API for external tools
The system SHALL expose REST endpoints so external tools can create scans,
poll status, fetch results, and export, authenticated by API token / OAuth
scope and rate-limited.

#### Scenario: Create a scan via API
- **WHEN** an external tool POSTs a scan request with a token bearing the
  `scan.execute` scope and the `scans.execute` permission
- **THEN** the system SHALL create the `ScanRun` and return its id and
  status

#### Scenario: API honors the inventory-scoping guardrail
- **WHEN** the inventory-scoping setting is enabled and an API scan request
  includes not-in-inventory IPs
- **THEN** the API SHALL respond with a client error listing the offending
  IPs and create no `ScanRun`

#### Scenario: Missing scope is rejected
- **WHEN** an API request presents a valid token that lacks the required
  scope
- **THEN** the system SHALL reject it with an authorization error
