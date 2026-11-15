# wasm-plugin-system Specification

## Purpose
Define packaging, validation, storage, agent assignment, and sandboxed WebAssembly execution requirements for ServiceRadar plugins.
## Requirements
### Requirement: Plugin Package Format
The system SHALL accept plugin packages that include a manifest YAML and a Wasm binary, and it SHALL validate required metadata (including resource requests) before storing or distributing the package.

#### Scenario: Valid package upload
- **GIVEN** a plugin package containing `plugin.yaml` and `plugin.wasm`
- **WHEN** the package is uploaded
- **THEN** the system validates required fields (`id`, `name`, `version`, `entrypoint`, `capabilities`, `outputs`, `resources`)
- **AND** stores the package only if validation succeeds

#### Scenario: Invalid package rejection
- **GIVEN** a plugin package missing `plugin.yaml`
- **WHEN** the package is uploaded
- **THEN** the system rejects the upload
- **AND** returns a validation error describing missing files

### Requirement: Plugin Package Storage Backends
The system SHALL store plugin packages using a configured backend and expose them through the web-ng API for agent download.

Blob upload and download authorization SHALL NOT embed bearer tokens in request URLs. Token-gated blob access SHALL use request headers or request bodies so signed tokens do not appear in generated URLs, copied links, logs, browser history, or agent configuration payloads.

#### Scenario: Filesystem-backed storage
- **GIVEN** the storage backend is configured as filesystem
- **WHEN** a package is uploaded
- **THEN** the package is stored under the configured path
- **AND** the web-ng API serves the package by reference ID

#### Scenario: JetStream object storage
- **GIVEN** the storage backend is configured as NATS JetStream object storage
- **WHEN** a package is uploaded
- **THEN** the package is written to the JetStream object store
- **AND** the web-ng API serves the package by object key

#### Scenario: GitHub repository source
- **GIVEN** a plugin package is configured to be sourced from a GitHub repository
- **WHEN** core fetches the package
- **THEN** core stores the package in the configured backend
- **AND** the web-ng API serves the package by reference ID

#### Scenario: Plugin blob download avoids URL-borne bearer tokens
- **GIVEN** an operator or agent requests a plugin blob
- **WHEN** the web-ng API authorizes the blob download
- **THEN** the bearer token is supplied via request header or body
- **AND** the request URL does not contain the signed token

### Requirement: Plugin Assignment and Distribution
The control plane SHALL allow assigning plugin packages to agents and SHALL deliver assignments through the agent config response.

Assignments SHALL NOT embed reusable bearer download URLs for plugin blobs. Agents SHALL receive only the internal plugin reference material needed to perform an authenticated fetch without a tokenized URL appearing in config payloads.

#### Scenario: Assign plugin to an agent
- **GIVEN** a plugin package exists
- **WHEN** an admin assigns the plugin to an agent
- **THEN** the next `AgentConfigResponse` includes a plugin assignment with package reference, schedule, and timeout
- **AND** the config version changes
- **AND** the assignment does not include a bearer token in the URL

#### Scenario: No assignment change
- **GIVEN** an agent with current plugin assignments
- **WHEN** the agent polls for config
- **THEN** the control plane returns `not_modified: true`
- **AND** the agent continues using cached plugin packages

### Requirement: Agent Wasm Runtime Sandbox
The agent MUST execute plugins in a sandboxed Wasm runtime with resource limits and must not expose raw filesystem or socket access.

#### Scenario: Resource limits enforced
- **GIVEN** a plugin configured with `requested_memory_mb: 32` and `requested_cpu_ms: 5000`
- **WHEN** the plugin executes
- **THEN** the agent enforces the memory limit
- **AND** terminates execution on timeout

#### Scenario: Plugin crash isolation
- **GIVEN** a plugin that traps or panics
- **WHEN** it executes
- **THEN** the agent reports an `UNKNOWN` result for that plugin
- **AND** the agent process continues running

### Requirement: Host Function Capabilities
Plugins SHALL access external resources only through declared host functions, and the agent SHALL enforce capability and permission checks on each call.

The runtime SHALL support authenticated HTTP requests through headers for VAPIX API access and SHALL continue enforcing allowlists for domains, networks, and ports.

#### Scenario: Authenticated VAPIX request succeeds with allowlist
- **GIVEN** a plugin configured with `http_request` capability and allowlisted AXIS domain/IP
- **AND** an HTTP request that includes authorization headers
- **WHEN** the plugin issues the request
- **THEN** the agent SHALL forward the request and return response payload to the plugin

#### Scenario: Authenticated request denied by allowlist
- **GIVEN** a plugin configured with `http_request` capability
- **AND** an HTTP request to a non-allowlisted AXIS endpoint
- **WHEN** the plugin issues the request
- **THEN** the agent SHALL deny the request regardless of headers

### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

Plugin results MAY include optional enrichment and event blocks. Camera-capable plugins MAY also publish camera source and stream descriptors for downstream inventory/relay use. Plugin results MUST NOT carry continuous live media payloads.

#### Scenario: Camera discovery plugin publishes descriptors
- **GIVEN** a camera discovery plugin result containing source identifiers, stream descriptors, and status
- **WHEN** the payload is ingested
- **THEN** service status ingestion SHALL still preserve the plugin status
- **AND** the camera descriptors SHALL be routed into camera inventory processing
- **AND** no live media bytes SHALL be expected in the plugin result payload

#### Scenario: Plugin result without camera descriptors
- **GIVEN** a standard plugin result payload containing only status and summary
- **WHEN** the payload is ingested
- **THEN** ingestion SHALL behave exactly as before

### Requirement: Plugin Result Ingestion Compatibility
The gateway/core ingestion pipeline MUST accept `serviceradar.plugin_result.v1` payloads without breaking existing checker ingestion, and it MUST preserve perfdata and structured metrics.

#### Scenario: Dedicated result processor
- **GIVEN** a plugin result payload in `serviceradar.plugin_result.v1`
- **WHEN** the gateway forwards the payload to core
- **THEN** core routes it through a plugin result processor that preserves perfdata and metrics

#### Scenario: Legacy checker ingestion unaffected
- **GIVEN** legacy checker statuses arriving at the gateway
- **WHEN** plugin results are enabled
- **THEN** the legacy ingestion path continues unchanged

### Requirement: Package Integrity Verification
The agent MUST verify package integrity using a hash and signature before executing a plugin.

#### Scenario: Invalid signature
- **GIVEN** a plugin package with a signature that does not match its hash
- **WHEN** the agent attempts to execute the plugin
- **THEN** the agent rejects the package
- **AND** reports an `UNKNOWN` result with an integrity error

### Requirement: GitHub Source Verification Policy
The system MUST allow configuring a policy that requires verification for GitHub-sourced plugin packages and it MUST enforce the policy in core before distribution.

#### Scenario: Verified GitHub package accepted
- **GIVEN** a GitHub-sourced plugin package with a valid GPG signature
- **WHEN** core validates the package
- **THEN** the package is accepted and stored for distribution

#### Scenario: Unverified package rejected
- **GIVEN** a GitHub-sourced plugin package without a valid GPG signature
- **AND** the verification policy requires verification
- **WHEN** core validates the package
- **THEN** the package is rejected
- **AND** it is not distributed to agents

### Requirement: Staged Import Review and Capability Confirmation
The system MUST stage every plugin import and require an explicit approve/deny decision with a diff view of requested vs approved capabilities and allowlists before a plugin is distributable.

#### Scenario: Import is staged with approve/deny
- **GIVEN** a newly uploaded or GitHub-sourced plugin package
- **WHEN** the package is staged for import
- **THEN** the system presents an approve/deny decision
- **AND** shows a diff view of requested vs approved capabilities and allowlists
- **AND** the package remains inactive until approved

#### Scenario: Capability override on import
- **GIVEN** a plugin requesting `http_request` and an allowlist of `api.example.com`
- **WHEN** an admin removes `http_request` or narrows the allowlist during import
- **THEN** the approved policy is persisted
- **AND** the plugin executes with the approved (reduced) capabilities

#### Scenario: Unapproved plugin not distributable
- **GIVEN** a plugin package that has not been approved
- **WHEN** an agent config is generated
- **THEN** the plugin is excluded from assignments

#### Scenario: Denied import remains blocked
- **GIVEN** a plugin package that was denied during import review
- **WHEN** an admin attempts to assign the plugin to an agent
- **THEN** the assignment is blocked

### Requirement: Core-Only GitHub Fetching
The system MUST ensure that agents never download plugin packages directly from GitHub.

#### Scenario: Agent receives only internal package references
- **GIVEN** a GitHub-sourced plugin assignment
- **WHEN** the agent fetches configuration
- **THEN** the assignment includes an internal package reference and hash
- **AND** no GitHub URL is provided to the agent

### Requirement: Package Caching
The agent SHALL cache plugin packages by content hash and avoid re-downloading unchanged packages.

#### Scenario: Cached package reuse
- **GIVEN** an agent has already downloaded a plugin package with hash `abc123`
- **WHEN** the agent receives a config update referencing the same hash
- **THEN** it reuses the cached package
- **AND** does not re-download the binary

### Requirement: Resource Budgeting and Admission Control
The system MUST support per-agent engine limits and per-plugin resource requests, and it MUST enforce admission control when requested resources exceed available capacity.

#### Scenario: Per-agent limits configured
- **GIVEN** an admin configures plugin engine limits for a specific agent (memory, CPU window, max concurrent plugins)
- **WHEN** the agent fetches configuration
- **THEN** the limits are applied to the plugin runtime

#### Scenario: Admission control rejects over-commit
- **GIVEN** per-agent limits of 256MB memory and 4 concurrent plugins
- **AND** existing plugin assignments already request 240MB and 4 slots
- **WHEN** a new plugin assignment requests 64MB and 1 slot
- **THEN** the assignment is rejected or queued
- **AND** the agent reports an `UNKNOWN` result indicating capacity exhaustion

### Requirement: Capacity Planning Visibility
The system SHALL expose plugin resource usage and capacity metrics in the Settings UI for each agent.

#### Scenario: Capacity view shows usage
- **GIVEN** an agent running multiple plugins
- **WHEN** an admin opens the agent capacity view
- **THEN** the UI shows current usage, configured limits, and remaining headroom

### Requirement: Runtime Telemetry Reporting
The agent MUST periodically report Wasm runtime health and resource usage telemetry to the control plane.

#### Scenario: Telemetry heartbeat
- **GIVEN** the agent has the Wasm runtime enabled
- **WHEN** the telemetry interval elapses
- **THEN** the agent submits a runtime status payload including engine health, resource usage, and recent execution stats
- **AND** the status is delivered through the normal `GatewayServiceStatus` pipeline

#### Scenario: Runtime unhealthy
- **GIVEN** the Wasm runtime fails to initialize or repeatedly crashes
- **WHEN** the agent emits runtime telemetry
- **THEN** the status indicates a degraded or unhealthy runtime
- **AND** the payload includes the failure reason

### Requirement: First-Party Wasm OCI Artifacts Publish Upload-Signature Metadata
First-party Wasm plugin OCI artifacts published by the repository SHALL include upload-signature metadata that is compatible with the control-plane uploaded-package verification policy.

#### Scenario: Published Wasm OCI artifact includes upload-signature sidecar
- **GIVEN** a first-party Wasm plugin bundle published to Harbor
- **WHEN** an operator or CI workflow inspects the OCI artifact
- **THEN** the artifact SHALL include the canonical bundle payload
- **AND** it SHALL include an additional upload-signature metadata sidecar
- **AND** the sidecar SHALL identify the signing key and plugin content hash

#### Scenario: Upload-signature payload matches control-plane verification semantics
- **GIVEN** a first-party Wasm plugin manifest and Wasm content hash
- **WHEN** the repository generates the upload-signature sidecar
- **THEN** the Ed25519 signature SHALL cover the same canonical payload used by `web-ng` upload verification
- **AND** the sidecar SHALL be sufficient for a later import workflow to verify package trust without inventing a first-party-only signature format

### Requirement: Release Verification Enforces Wasm Upload Signatures
The repository release and verification workflows SHALL fail first-party Wasm plugin publication when the upload-signature sidecar is missing or invalid.

#### Scenario: Valid upload-signature sidecar passes verification
- **GIVEN** a published first-party Wasm plugin OCI artifact with a valid upload-signature sidecar
- **WHEN** the repository verification workflow runs
- **THEN** the workflow SHALL verify the upload-signature metadata against the trusted public key
- **AND** the artifact SHALL be considered publishable

#### Scenario: Missing or invalid upload-signature sidecar fails verification
- **GIVEN** a published first-party Wasm plugin OCI artifact missing the upload-signature sidecar or containing an invalid Ed25519 signature
- **WHEN** the repository verification workflow runs
- **THEN** verification SHALL fail
- **AND** the release workflow SHALL NOT treat the plugin artifact as successfully published

### Requirement: First-party plugin publication artifacts match the bundle contract
First-party Wasm plugins published by the repository SHALL use the same bundle contract accepted by the plugin import system rather than publishing a naked Wasm binary alone.

#### Scenario: Published artifact contains importable bundle contents
- **GIVEN** a first-party Wasm plugin published to Harbor
- **WHEN** the artifact payload is fetched
- **THEN** it SHALL contain the plugin manifest and Wasm binary
- **AND** it MAY contain optional sidecar files such as config schema or display contract

#### Scenario: Published artifact remains compatible with import validation
- **GIVEN** a first-party Wasm plugin bundle published from the repository
- **WHEN** the bundle is later submitted to the control-plane import flow
- **THEN** the same manifest and sidecar validation rules SHALL apply
- **AND** no alternate first-party-only package format SHALL be required

### Requirement: Streaming plugins use a distinct long-lived runtime mode
The agent SHALL support a distinct streaming plugin mode for Wasm plugins that need to maintain a live media session. This mode SHALL be separate from the bounded execution path used for scheduled plugins that emit `serviceradar.plugin_result.v1`.

#### Scenario: Streaming plugin runs without using the one-shot result runtime
- **GIVEN** a Wasm plugin assignment with streaming media capability
- **WHEN** the agent starts the plugin for a camera relay session
- **THEN** the plugin SHALL run in the streaming plugin mode
- **AND** the agent SHALL NOT require the plugin to terminate immediately after emitting a `plugin_result`

### Requirement: Streaming plugins use a host media bridge
Streaming plugins SHALL access live camera media transport through dedicated host functions for media session open, chunk write, heartbeat, and close. The agent SHALL enforce capability and permission checks on those calls.

#### Scenario: Streaming plugin writes media through host functions
- **GIVEN** a streaming plugin has been granted camera media capability
- **WHEN** the plugin opens a relay session and writes encoded media chunks
- **THEN** it SHALL do so through the host media bridge
- **AND** the agent SHALL reject media bridge calls from plugins without the required capability

### Requirement: Per-Rule Plugin Assignment Ownership
The control plane SHALL allow an agent to hold more than one enabled assignment for the same plugin when the assignments are owned by different credential rules, and SHALL otherwise keep at most one enabled assignment per (partition, agent, plugin).
Ownership SHALL be derived from the assignment's policy id: `network-credential-rule:<rule id>` with any suffix is owned by that rule; a manual assignment or any other policy id keeps the original single-assignment rule. Reconciliation SHALL NOT adopt an assignment owned by a different credential rule.

#### Scenario: Inventory and interface check rules coexist
- **GIVEN** an agent with an enabled `opentext-nom-inventory` assignment owned by an inventory credential rule
- **WHEN** an interface config check credential rule provisions an assignment for the same plugin on that agent
- **THEN** both assignments are enabled
- **AND** neither assignment is overwritten

#### Scenario: A rule's drifted policy id still converges
- **GIVEN** an enabled assignment owned by a credential rule under an older policy id suffix
- **WHEN** the same rule is reconciled under its current policy id
- **THEN** the existing assignment is adopted and no second enabled assignment is created

#### Scenario: Manual assignments keep the single-assignment rule
- **GIVEN** an enabled manual assignment for a plugin on an agent
- **WHEN** a second enabled assignment for that plugin is created on the agent
- **THEN** the create is rejected

### Requirement: Producer Schedule Target Items
A producer schedule SHALL be able to declare `target_input` naming the schedule params that hold an SRQL device query and an optional list of device fields, and the dispatcher SHALL resolve that query when the schedule runs and deliver the resulting device items as `target_items` on each run.
Delivered items SHALL be the normalized device rows, capped at the declared `max_items` (at most 1000) with the total and a truncation flag reported. A run whose configured query is missing SHALL fail rather than dispatch with no targets.

#### Scenario: Endpoints are delivered with their attachment
- **GIVEN** a schedule declaring `target_input` with `query_param: target_query` and `fields_param: target_fields`
- **AND** params `target_query: in:devices switch_port_attachment.switch_hostname:%` and `target_fields: [switch_port_attachment]`
- **WHEN** the schedule dispatches
- **THEN** each run payload carries `target_items.items` with each matched device and its `fields.switch_port_attachment`

#### Scenario: Missing query
- **GIVEN** a schedule declaring `target_input` whose params have no target query
- **WHEN** the schedule dispatches
- **THEN** the dispatch fails with `missing_target_query`

### Requirement: Projected Target Fields
Device target inputs SHALL accept a list of fields to copy from each SRQL device row into the item under `fields`, where each field is a top-level device column or `metadata.<key>`.
The whole `metadata` map and any other path form SHALL be rejected, and non-device inputs SHALL NOT accept fields.

#### Scenario: A metadata key is projected
- **GIVEN** fields `["metadata.armis_access_switch"]`
- **WHEN** a device row whose metadata has `armis_access_switch: switch01.example.com:gi1/0/7` is normalized
- **THEN** the item carries `fields["metadata.armis_access_switch"]` and no other metadata

#### Scenario: Whole metadata is rejected
- **GIVEN** fields `["metadata"]`
- **WHEN** the input is resolved
- **THEN** it is rejected with an invalid-field error

### Requirement: Plugin assignment JSON identity
The `/api/admin/plugin-assignments` JSON API SHALL include `plugin_id` on every assignment object it returns, and SHALL expose `GET /api/admin/plugin-assignments/{id}` for a single assignment, using the same authentication and `plugins.view` / `plugins.assign` permissions as the existing list/create/update/delete routes.

#### Scenario: List includes plugin_id
- **GIVEN** an enabled assignment of package `netbox-inventory` to an agent
- **WHEN** an authorized caller GET `/api/admin/plugin-assignments`
- **THEN** that assignment object SHALL include `plugin_id` `netbox-inventory`

#### Scenario: Get one assignment
- **GIVEN** an assignment id returned by create or list
- **WHEN** an authorized caller GET `/api/admin/plugin-assignments/{id}`
- **THEN** the system SHALL return that assignment
- **AND** SHALL NOT include secret values inside `params`

### Requirement: Policy Target Queries Are Read Whole
The control plane SHALL read the whole selection of a plugin target policy's input definitions, a credential rule's target query, and a producer schedule's `target_query` or `target_input` query whenever it plans, retracts, dispatches, or previews from them, a page at a time with an explicit page limit. It SHALL NOT treat one SRQL page as the whole selection. A selection that cannot be read whole SHALL fail the operation rather than act on, or report, a partial selection. A preview SHALL report the whole selection's counts, and any list it shows SHALL be bounded and labelled as a sample.

#### Scenario: Credential rule selecting more than one page
- **GIVEN** an enabled credential rule whose target query selects more devices than one SRQL page returns
- **WHEN** the rule is reconciled for its agent
- **THEN** every selected device is delivered in one of the rule's assignments

#### Scenario: Editing a wide target policy
- **GIVEN** an enabled target policy whose input selects more agents than one SRQL page returns, with an enabled assignment on each
- **WHEN** an operator changes the policy's input definitions without excluding any of those agents
- **THEN** no assignment is retracted

#### Scenario: Previewing a wide selection
- **GIVEN** a credential rule or target policy whose query selects more devices than one SRQL page returns
- **WHEN** an operator previews it
- **THEN** the preview reports the number of devices the whole selection matches
- **AND** any device list it shows is bounded and labelled as a sample

#### Scenario: Producer schedule target items beyond one page
- **GIVEN** a producer schedule whose `target_input` query matches more devices than its `max_items`
- **WHEN** the schedule dispatches
- **THEN** the run carries at most `max_items` items, the total the whole query matched, and a truncation flag

#### Scenario: Selection cannot be read whole
- **GIVEN** a target query whose selection continues past SRQL's cursor window
- **WHEN** the control plane reads it
- **THEN** the operation fails with an error naming the cursor window
- **AND** nothing is planned, retracted, or dispatched from a partial selection

### Requirement: Plugin result handlers classify outcomes into four explicit dispositions
Every platform handler registered with `ServiceRadar.Observability.PluginResultIngestor` SHALL implement `ServiceRadar.Observability.PluginResultHandler`, declare closed disjoint `settled_reasons/0` and `refused_reasons/0` atom lists, and return an outcome classified into one of four dispositions: `applied` (`:ok`), `settled` (`{:settled, reason}` or `{:settled, reason, metadata}`), `refused` (`{:refused, reason}` or `{:refused, reason, metadata}`), or `retryable` (`{:error, reason}`).

`settled` SHALL be returned only when the plugin result was authentically produced and structurally valid, and persisted control-plane state proves its authority was withdrawn or its ordering generation was superseded before projection. A `settled` outcome SHALL preserve the reported `service_status` row, record a `"settled"` handler marker in `details["downstream_ingest"]` without forcing `service_state.available` to `false`, emit one structured log entry and one bounded counter increment, and acknowledge the durable edge record on its first delivery.

`refused` SHALL be returned for deterministic contract, provenance, ownership, capability, integrity, ceiling, or schema violations that cannot succeed on redelivery of the same record bytes, including `:plugin_assignment_not_found` when a policy-managed assignment row does not exist to prove ownership. A `refused` outcome SHALL persist the `"failed"` handler marker for status visibility and route the enclosing durable edge record to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on its first delivery under its bounded `reason` atom.

`retryable` SHALL be returned for transient database, lock, graph, queue, or object-store failures so JetStream redelivers with backoff up to `dead_letter_after_deliveries`. Any handler `{:error, term}` whose reason is not a declared `settled` or `refused` outcome SHALL default to `retryable` and, when unclassified, SHALL emit `[:serviceradar, :plugin_result, :handler, :unclassified_error]` so unmigrated error shapes never drop or prematurely dead-letter data. Missing optional or failed identity fields in outcome metadata and logs SHALL remain `nil` and SHALL NOT be stringified to `"nil"`.

#### Scenario: Withdrawn Proxmox assignment settles on first delivery
- **GIVEN** a valid Proxmox inventory plugin result batch whose policy-owned `PluginAssignment` row matches the authenticated agent and partition and has `enabled: false` (`:plugin_assignment_disabled`)
- **WHEN** `WasmPluginResult` projects the edge record through `PluginResultIngestor`
- **THEN** the handler SHALL return `{:settled, :plugin_assignment_disabled, metadata}`
- **AND** `PluginResultIngestor` SHALL preserve the reported `service_status` row with a `"settled"` downstream marker without marking the service unavailable
- **AND** `EdgeRecord` SHALL commit the delivery slot and event ledger and acknowledge the message on delivery 1 without dead-lettering it

#### Scenario: Missing Proxmox assignment row is refused on first delivery
- **GIVEN** a Proxmox inventory plugin result batch naming an `assignment_id` that has no `PluginAssignment` row in `platform.plugin_assignments`
- **WHEN** `WasmPluginResult` projects the edge record through `PluginResultIngestor`
- **THEN** the handler SHALL return `{:refused, :plugin_assignment_not_found, metadata}` because ownership invariants cannot be verified
- **AND** `EdgeRecord` SHALL fail the record with `EdgeRecordRefusedError` so `EdgeRecordDeadLetter` copies it to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on delivery 1 with `Sr-Edge-Dlq-Reason` set to `plugin_assignment_not_found`

#### Scenario: Unclassified handler error defaults to retryable and emits diagnostic telemetry
- **GIVEN** a registered plugin result handler that returns an undeclared `{:error, :unexpected_ad_hoc_atom}` tuple
- **WHEN** `PluginResultIngestor` classifies the handler return
- **THEN** it SHALL emit `[:serviceradar, :plugin_result, :handler, :unclassified_error]`
- **AND** it SHALL classify the outcome as `retryable` so the durable edge record is redelivered rather than acknowledged or dead-lettered on delivery 1

#### Scenario: Missing provenance or target identity stays nil
- **GIVEN** a plugin result whose `settled` or `refused` path runs when an optional or unparsed identity field is absent
- **WHEN** the handler and coordinator build outcome metadata and structured log fields
- **THEN** the absent identity field SHALL remain `nil`
- **AND** no log field, marker attribute, or metric tag SHALL coerce `nil` into the string `"nil"`

### Requirement: Multi-handler plugin results resolve under a deterministic precedence lattice
When a `serviceradar.plugin_result.v1` item matches multiple registered handlers in `ServiceRadar.Observability.PluginResultIngestor`, the coordinator SHALL evaluate all matching handlers, record each handler's individual status (`"succeeded"`, `"settled"`, or `"failed"`) in `details["downstream_ingest"]`, and combine their dispositions using the precedence order `retryable > refused > applied > settled`.

Within `ServiceRadar.Inventory.DeviceDiscoveryIngestor`, a payload mixing superseded AWX inventory observations with un-ruled generic `device_discovery` items SHALL NOT settle as `:stale_awx_membership_generation`; it SHALL return `{:refused, :mixed_superseded_awx_observation, metadata}` so un-ruled discovery items are never acknowledged unapplied.

#### Scenario: Applied and settled handlers on the same result commit as applied
- **GIVEN** a plugin result that matches two handlers where one returns `:ok` (`applied`) and the other returns `{:settled, :device_out_of_service, metadata}`
- **WHEN** `PluginResultIngestor` combines their outcomes
- **THEN** the per-handler markers SHALL record `"succeeded"` for the first handler and `"settled"` for the second
- **AND** the combined result SHALL be `:ok` (`applied`), committing the ledger and acknowledging on delivery 1

#### Scenario: Retryable outranks refused and settled in a multi-handler result
- **GIVEN** a plugin result that matches two handlers where one returns `{:refused, reason, metadata}` (or `{:settled, reason, metadata}`) and the other returns a `retryable` `{:error, timeout}`
- **WHEN** `PluginResultIngestor` combines their outcomes
- **THEN** the combined result SHALL be `retryable` so the message is redelivered with backoff and neither acknowledged unapplied nor dead-lettered prematurely

#### Scenario: Mixed superseded AWX and un-ruled discovery payload is refused
- **GIVEN** a plugin result carrying both a superseded AWX controller membership observation and generic non-AWX `device_discovery` entries
- **WHEN** `DeviceDiscoveryIngestor` evaluates the payload
- **THEN** it SHALL return `{:refused, :mixed_superseded_awx_observation, metadata}` rather than settling the batch

### Requirement: Plugin handler outcomes emit one bounded telemetry family and preserve staged artifacts until commit
The control plane SHALL record every evaluated plugin handler outcome under the bounded metric `serviceradar.plugin_result.handler.outcome.count` (`[:serviceradar, :plugin_result, :handler, :outcome]`) tagged only by `[:outcome, :handler, :reason]`, folding superseded AWX observations and withdrawn Proxmox assignments into that single metric family rather than maintaining per-handler counters or unbounded instance tags.

Out-of-line staged artifacts referenced by a `serviceradar.plugin_results.batch` record (such as staged running-config objects read by `ServiceRadar.NetworkConfig.PluginIngestor`) SHALL NOT be deleted when an ingest attempt returns `retryable` or `refused`. On the durable edge-record path, staged artifacts SHALL be deleted only in `WasmPluginResult.committed/3` after the delivery slot and event ledger transaction commits for an `applied` or `settled` primary delivery.

#### Scenario: Staged running-config artifact survives transient failure and DLQ replay
- **GIVEN** a `serviceradar.plugin_results.batch` record referencing a staged running-config object in the object store
- **WHEN** delivery 1 fails with a `retryable` database timeout or is dead-lettered with a `refused` outcome
- **THEN** `PluginIngestor` SHALL NOT delete the staged object during the failed or refused attempt
- **AND** a subsequent retry or `EdgeRecordDeadLetter.Replay` run SHALL still be able to fetch the staged object, deleting it only after `WasmPluginResult.committed/3` runs following ledger commit

#### Scenario: Handler outcome metric tags remain bounded
- **GIVEN** `AwxInventoryObservationFence` settling observations across many distinct AWX `controller_id` UUIDs and `ProxmoxSourceScopeResolver` settling results across many `assignment_id` UUIDs
- **WHEN** handler outcome telemetry is emitted to Prometheus
- **THEN** `serviceradar.plugin_result.handler.outcome.count` SHALL carry only bounded `:outcome`, `:handler`, and `:reason` tags
- **AND** `controller_id` and `assignment_id` SHALL appear only in untagged `:telemetry` metadata and single-shot structured logs

