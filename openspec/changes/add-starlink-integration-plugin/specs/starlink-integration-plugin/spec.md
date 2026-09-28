## ADDED Requirements

### Requirement: Starlink Plugin Packages
The system SHALL provide a first-party Go WASM plugin module under
`go/cmd/wasm-plugins/starlink/`, built with `serviceradar-sdk-go` and the Bazel WASM
pipeline, that ships a `starlink-cloud` package for the vendor cloud APIs and a
`starlink-local` package for device-local APIs.

#### Scenario: Both packages build and bundle
- **WHEN** `//build/wasm_plugins:all_bundles` is built
- **THEN** signed-publishable bundles for `starlink-cloud` and `starlink-local` are produced from the same Go module

#### Scenario: Local package requires gRPC capability
- **WHEN** `starlink-local` is assigned to an agent that does not advertise the `grpc_request` capability
- **THEN** admission rejects the assignment with a capability error instead of running the plugin

### Requirement: Starlink Service Account Credentials
The `starlink-cloud` manifest SHALL declare a `starlink` credential profile whose auth method
collects a client ID, a secret client secret and an optional managed account number,
provisioned as producer schedules whose credential requirement grant uses host-side
`oauth2_client_credentials` token exchange, so that scheduled collection runs in action mode
with an injected bearer token and the guest never receives the client secret.

#### Scenario: Token obtained by the host
- **WHEN** a scheduled `starlink-cloud` run makes a Management API request
- **THEN** the agent host exchanges the brokered client credentials for an access token, injects it as a bearer header, and the guest config contains no client secret

#### Scenario: Managed child account
- **WHEN** a credential rule sets an account number
- **THEN** the token request includes that account number and API calls are scoped to that account

#### Scenario: Read runs cannot mutate
- **WHEN** a scheduled run attempts a method and path outside the read allow list
- **THEN** the host refuses the request and the run reports the denial

### Requirement: Starlink Inventory Discovery
The `starlink-cloud` plugin SHALL poll the Management API V2 on a schedule, discover every
user terminal and router visible to the service account, and add or update them in
ServiceRadar inventory through `serviceradar.device_discovery.v1` snapshots.

#### Scenario: New terminal appears
- **WHEN** a user terminal is added to the account between two runs
- **THEN** the next complete snapshot contains it and it appears in ServiceRadar inventory with its service line, product and nickname as metadata

#### Scenario: Partial pagination failure
- **WHEN** any page of a listing fails during a run
- **THEN** the snapshot is emitted with `snapshot_complete: false` and no device is treated as absent because of that run

#### Scenario: Terminal removed from account
- **WHEN** a previously discovered terminal is absent from a complete snapshot
- **THEN** it follows the external inventory availability lifecycle and the plugin does not request deletion

### Requirement: Starlink Device Identity
The plugins SHALL identify Starlink devices only by vendor device ID, emitted as both
`device_id` and `metadata.integration_id` in the form `starlink:ut:<id>` or
`starlink:router:<id>`, and SHALL NOT emit public IP addresses, vendor-default LAN addresses,
serials, or blank/placeholder values as device identifiers.

#### Scenario: Shared public IP
- **WHEN** two terminals report the same public IPv4 address
- **THEN** both remain distinct devices and the address is stored only as metadata

#### Scenario: Local result converges on cloud device
- **WHEN** `starlink-local` reads a terminal whose vendor ID the cloud plugin already discovered
- **THEN** local metrics and events attach to the same device and no second device is created

#### Scenario: Metrics land on the discovered device
- **WHEN** the cloud plugin emits a terminal metric with device reference `starlink:ut:<id>` after discovering that terminal
- **THEN** the stored metric row carries the terminal's canonical device uid

#### Scenario: Placeholder identifier
- **WHEN** a vendor record carries an empty or all-zero identifier
- **THEN** that identifier is dropped from the discovery record

### Requirement: Starlink Telemetry Collection
The `starlink-cloud` plugin SHALL drain the Starlink telemetry stream in bounded iterations
and emit terminal and router measurements as `serviceradar.metric.v1` records through
`EmitTelemetry`, decoding columns by the names in each response.

#### Scenario: Metrics flow through JetStream
- **WHEN** a telemetry batch is received
- **THEN** metrics are emitted via `EmitTelemetry` and are not included in the plugin result or written to any database by the plugin

#### Scenario: Column order changes
- **WHEN** the vendor reorders telemetry columns between responses
- **THEN** every value is still mapped to the correct metric name

#### Scenario: Backlog exceeds one run
- **WHEN** the stream backlog is larger than the per-run iteration budget
- **THEN** the run stops at the budget, reports success, and the remaining backlog is drained by later runs

#### Scenario: Telemetry gap detected
- **WHEN** no telemetry arrives for longer than the configured interval while devices are known online
- **THEN** the run reports a warning status that names the gap

### Requirement: Starlink Alerts As Events
The plugins SHALL convert active Starlink alerts into OCSF events carrying a declared
signal schema and a per-device, per-alert condition key, and SHALL map numeric alert codes
only through the enum metadata of the same response.

#### Scenario: Alert raised and cleared
- **WHEN** a terminal reports an active alert on one run and no longer reports it on a later run
- **THEN** the agent produces one raise event and one clear event for that device and alert, and the plugin emits no event for alerts that were never active

#### Scenario: Unknown alert code
- **WHEN** a numeric alert code is not present in the response enum metadata
- **THEN** an event named `unknown_alert_<code>` is emitted instead of dropping or guessing the alert

#### Scenario: Proposed alert rules start disabled
- **WHEN** the `starlink-cloud` package is approved
- **THEN** its proposed alert rules are created disabled

### Requirement: Starlink Management Actions
The `starlink-cloud` manifest SHALL declare northbound actions for terminal and router reboot,
terminal swap on a service line, terminal move between managed accounts, and service-line
product change, deactivation and reactivation; every action except reboot SHALL be
classified `destructive` and every action SHALL require confirmation.

#### Scenario: Swap resumes after interruption
- **WHEN** a terminal swap fails after removing the old terminal but before adding the new one
- **THEN** the persisted continuation state resumes at the add step on retry and does not repeat completed steps

#### Scenario: Preflight rejects swap
- **WHEN** the service line product would exceed its maximum terminal count
- **THEN** the action fails in preflight before any vendor mutation

#### Scenario: Account move uses two scoped credentials
- **WHEN** a terminal is moved between managed accounts
- **THEN** the source-account steps use the source credential rule and the destination-account steps use the destination credential rule

#### Scenario: Every step is audited
- **WHEN** any management action step completes or fails
- **THEN** an OCSF audit event records the action, target device, step and outcome without secrets

### Requirement: Starlink Local Diagnostics
The `starlink-local` plugin SHALL read vendor-documented diagnostics from terminals and
routers on the agent's LAN, and SHALL call community-documented read methods only when the
assignment explicitly enables unofficial methods.

#### Scenario: Default assignment
- **WHEN** `starlink-local` runs with default configuration
- **THEN** it calls only vendor-documented diagnostics and emits their alerts and metrics

#### Scenario: Unofficial methods enabled
- **WHEN** `enable_unofficial_methods` is true and a community method fails or changes shape
- **THEN** the run degrades to diagnostics-only data and reports a warning instead of failing

#### Scenario: No control methods
- **WHEN** any `starlink-local` configuration is used
- **THEN** the plugin never issues stow, power-save, GPS-inhibit, reboot or factory-reset requests to the local API

### Requirement: Starlink Fixtures Are Synthetic
All Starlink plugin fixtures, examples and documentation SHALL use invented identifiers,
reserved documentation addresses and invented account and service-line values.

#### Scenario: Fixture review
- **WHEN** a Starlink fixture or doc example is added
- **THEN** every device ID, serial, account number, service line, address and coordinate in it is synthetic
