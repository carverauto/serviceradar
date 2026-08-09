## ADDED Requirements

### Requirement: Ansible Controller Registration

The system SHALL allow operators with `ansible.controllers.manage` permission to register one or more AWX/AAP controllers, storing the controller's base URL, version, the agent that reaches it, and a reference to a credential broker entry holding the API token. The API token SHALL be held by the existing credential broker (the same pattern used for proxmox / unifi controller secrets) and SHALL never be returned in any API response or LiveView assign in clear text.

#### Scenario: Operator registers an AWX controller

- **GIVEN** an operator with `ansible.controllers.manage` permission
- **WHEN** they submit a controller form with base_url, api_token, and the agent_id that can reach the controller
- **THEN** the system SHALL write the api_token into the credential broker and store only the broker reference on the resource
- **AND** the system SHALL dispatch an `awx.ping` command via `AgentCommandBus` to that agent
- **AND** SHALL store the ping result on `last_health_at` and `status`
- **AND** the controller SHALL appear in the `/settings/ansible` controllers tab

#### Scenario: Operator without permission attempts to register a controller

- **GIVEN** an operator without `ansible.controllers.manage` permission
- **WHEN** they navigate to `/settings/ansible`
- **THEN** the system SHALL deny access via the existing RBAC route protection
- **AND** the controllers tab SHALL not be reachable in the navigation

#### Scenario: API token is never exposed after creation

- **GIVEN** a registered AnsibleController
- **WHEN** any operator views the controller detail page or queries it via the API
- **THEN** the response SHALL NOT include the api_token, only the broker reference
- **AND** the form for editing the controller SHALL render the api_token as a write-only field that updates the broker entry

---

### Requirement: Polymorphic Playbook Catalog Sources

The system SHALL support catalog playbooks from two source types in v1: `git` (registered `PlaybookRepository` records) and `awx` (Job Templates discovered via the AWX REST API). The `Playbook` resource SHALL carry a `source_type` discriminator and the appropriate source reference. Operators SHALL be able to use either source or both simultaneously; the same logical playbook reachable through both sources SHALL produce two distinct catalog entries with clear source badges.

#### Scenario: Operator runs both source types

- **GIVEN** a registered git `PlaybookRepository` containing `deploy.yml` AND a registered `AnsibleController` whose AWX has a Job Template named "Deploy"
- **WHEN** both catalog sync workers run
- **THEN** the catalog SHALL contain a `Playbook` with `source_type = "git"` for `deploy.yml`
- **AND** a separate `Playbook` with `source_type = "awx"` for the AWX template
- **AND** the catalog UI SHALL display each entry with a source badge identifying its origin

#### Scenario: AWX-sourced playbook variable prompts come from survey_spec

- **GIVEN** an AWX Job Template with a `survey_spec` defining a question "Target version"
- **WHEN** the AWX catalog sync worker imports the template
- **THEN** the resulting `Playbook` row SHALL carry the `survey_spec` jsonb intact
- **AND** the launch dialog SHALL render the survey questions as typed inputs, identical to how `vars_prompt` renders for git-sourced playbooks

---

### Requirement: Git Repository Sync

The system SHALL allow operators with `ansible.repositories.manage` permission to register one or more git repositories as a playbook catalog source. An AshOban worker SHALL clone or pull each repository on its configured `sync_interval`, walk YAML files, parse playbook metadata, and upsert `Playbook` rows with `source_type = "git"`.

#### Scenario: Operator registers a public git repository

- **GIVEN** an operator with `ansible.repositories.manage` permission
- **WHEN** they submit a repository form with git_url, ref, and sync_interval
- **THEN** the system SHALL persist the repository
- **AND** the next AshOban tick SHALL clone the repository, parse playbooks, and create catalog entries
- **AND** `last_sync_at` and `last_sync_status` SHALL reflect the outcome

#### Scenario: Repository contains a playbook with malformed YAML

- **GIVEN** a registered repository with at least one syntactically broken playbook file
- **WHEN** the sync worker runs
- **THEN** the broken playbook SHALL be persisted with `parse_status: error` and a `parse_diagnostics` payload describing the parse failure
- **AND** valid playbooks in the same repository SHALL still be persisted with `parse_status: ok`
- **AND** the broken entry SHALL be visible in the catalog UI as "broken" rather than missing

#### Scenario: Private repository with deploy token

- **GIVEN** a repository configured with a deploy token (HTTPS only)
- **WHEN** the sync worker authenticates to the remote
- **THEN** the token SHALL be retrieved through AshCloak decryption
- **AND** the token SHALL never be written to logs or NATS events

---

### Requirement: Playbook Catalog Metadata Parsing

The system SHALL parse each playbook YAML file to extract: `name`, `description` (from a leading comment block or `description` key), declared variables (top-level `vars`), `vars_prompt` definitions, `tags`, and `hosts` pattern. Parsed metadata SHALL be stored on the `Playbook` Ash resource for catalog discovery and review. Mutable git metadata, `vars_prompt`, and AWX `survey_spec` SHALL NOT become the hardened browser launch contract; secure launch inputs SHALL come only from the current approved binding's typed non-secret schema.

#### Scenario: Git playbook declares vars_prompt entries

- **GIVEN** a playbook with `vars_prompt: [{name: "version", prompt: "Target version"}]`
- **WHEN** the repository sync parses the playbook
- **THEN** the catalog SHALL retain the prompt as review metadata
- **AND** the git-sourced row SHALL NOT become selectable in the hardened launch UI

#### Scenario: Approved binding declares non-secret inputs

- **GIVEN** a current approved AWX binding with typed public or internal inputs
- **WHEN** an operator selects its AWX-sourced playbook
- **THEN** the launch UI SHALL render only those declared non-secret fields
- **AND** raw JSON/YAML, password fields, undeclared names, and sensitive or target-changing variables SHALL NOT be accepted

---

### Requirement: Reviewed AWX Job Template Binding

A `git`-sourced `Playbook` catalog entry MAY retain an optional `awx_job_template_id` as catalog metadata, but that field SHALL NOT confer launch authority. The hardened launch UI SHALL select only parse-valid AWX-sourced playbooks. An AWX-sourced row SHALL be launchable only when the system resolves a current approved immutable binding for its controller and job-template ID and live preflight matches that binding.

#### Scenario: Operator views a git-sourced playbook with a template ID

- **GIVEN** a `git`-sourced Playbook with or without an `awx_job_template_id`
- **WHEN** the operator opens the launch flow
- **THEN** that playbook SHALL NOT appear in the selectable list
- **AND** the catalog browser MAY continue to show its source and template metadata

#### Scenario: AWX-sourced playbook lacks a current approved binding

- **GIVEN** an `awx`-sourced Playbook
- **AND** its current template binding is missing, expired, revoked, or drifted
- **WHEN** the operator selects it in the launch flow
- **THEN** the system SHALL keep launch unavailable and surface an operator-safe readiness message

#### Scenario: AWX job template referenced by binding has been deleted

- **GIVEN** a Playbook bound to a job template that no longer exists in AWX
- **WHEN** an operator attempts to launch
- **THEN** live preflight SHALL reject the launch before operation persistence or dispatch
- **AND** the launch UI SHALL surface an operator-safe readiness message

---

### Requirement: Retained Internal Run Lifecycle State Machine

The retained internal `PlaybookRun` resource SHALL remain an Ash State Machine with states `pending`, `launching`, `running`, `succeeded`, `partial`, `failed`, `unreachable`, `canceled`. Allowed transitions SHALL be: `pending → launching`, `launching → running | failed | unreachable`, `running → succeeded | partial | failed | unreachable | canceled`. Terminal states SHALL NOT transition further. `partial` SHALL be reached only when retained `PlaybookRunTarget` outcomes are mixed; `failed` SHALL be reached when every target failed. Hardened interactive launch SHALL NOT create or depend on this resource.

#### Scenario: Retained internal run progresses through states

- **GIVEN** an existing internal run awaiting AWX event ingestion
- **WHEN** the internal run is in `pending`
- **THEN** the run SHALL be in `pending`
- **AND** the internal lifecycle service MAY transition it to `launching` after correlating the AWX job
- **AND** the ingestor SHALL transition it to `running` after the first event arrives
- **AND** the ingestor SHALL transition it to `succeeded` when AWX reports `successful` and the single target succeeded

#### Scenario: Multi-device run with mixed outcomes resolves to partial

- **GIVEN** a run launched against three devices where two succeed and one fails
- **WHEN** the AWX job reports terminal status
- **THEN** the corresponding `PlaybookRunTarget` rows SHALL each carry their actual outcome
- **AND** the `PlaybookRun` SHALL transition to `partial`

#### Scenario: Multi-device run where every target fails resolves to failed

- **GIVEN** a run launched against three devices where all three fail
- **WHEN** the AWX job reports terminal status
- **THEN** the `PlaybookRun` SHALL transition to `failed`

#### Scenario: Ingestor cannot move a terminal run back to running

- **GIVEN** a `PlaybookRun` in state `succeeded`
- **WHEN** the ingestor processes a delayed event for that run
- **THEN** the state machine SHALL reject the transition to `running`
- **AND** the late event SHALL still be persisted to the task results table for completeness

#### Scenario: Operator cancels a running job

- **GIVEN** an operator with `ansible.runs.cancel` permission and an internal run in `running`
- **WHEN** cancellation is requested through the authorized service
- **THEN** the system SHALL dispatch `awx.cancel_job` via the bus
- **AND** transition the internal run to `canceled` once AWX confirms

---

### Requirement: Hardened Launch Authorization

The system SHALL allow a hardened launch only when the current human actor has `ansible.runs.launch`, the selected catalog row is parse-valid and AWX-sourced, a current approved immutable binding exists, every canonical device resolves to exactly one current approved durable AWX membership, all memberships share one controller and inventory allowed by the binding, no target has an active hold, the selected edge principal is authenticated, and live AWX preflight exactly matches the reviewed binding. Submit SHALL re-resolve these conditions and accept only the binding's declared typed non-secret inputs.

#### Scenario: Operator launches against an unmanaged device

- **GIVEN** a device with `ansible_managed = false` selected as a target
- **WHEN** an operator prepares a launch
- **THEN** the system SHALL reject the selection with an operator-safe readiness message
- **AND** SHALL NOT create an operation, execution, internal run, or AWX launch command

#### Scenario: Multi-device selection spans multiple controllers

- **GIVEN** five selected devices where three are managed by Controller A and two by Controller B
- **WHEN** the operator prepares the launch
- **THEN** the system SHALL refuse to proceed with the mixed selection
- **AND** SHALL surface an operator-safe message explaining that every target must share one approved controller and inventory partition

#### Scenario: Controller's agent is offline at launch time

- **GIVEN** an AnsibleController whose agent is not currently connected to the gateway
- **WHEN** an operator with `ansible.runs.launch` attempts to launch
- **THEN** the system SHALL reject the launch with an operator-safe error explaining the agent is unreachable
- **AND** SHALL NOT create an `AutomationOperation`, `AutomationExecution`, `PlaybookRun`, or AWX launch command

---

### Requirement: Retained Internal Run Hierarchy Persistence

The system SHALL retain the existing internal hierarchy of `PlaybookRun → PlaybookRunTarget` and `PlaybookRun → PlaybookPlay → PlaybookTask → PlaybookTaskResult` for historical and still-registered ingestion, audit, retention, and SRQL dependencies. Each retained `PlaybookTaskResult` SHALL reference both its `PlaybookTask` and its `PlaybookRunTarget`, and per-task stdout/stderr blobs SHALL remain deduplicated by sha256 through `PlaybookContent`. Hardened interactive launches SHALL persist `AutomationOperation`, `AutomationExecution`, and exact immutable execution targets instead of creating this hierarchy.

#### Scenario: A retained internal run ingests multiple plays

- **GIVEN** a retained internal run with 2 plays, each containing 5 tasks across 3 attributed targets
- **WHEN** its event ingestion completes
- **THEN** the database SHALL contain 1 PlaybookRun, 3 PlaybookRunTargets, 2 PlaybookPlays, 10 PlaybookTasks, up to 30 PlaybookTaskResults each linked to its target
- **AND** identical task stdout across tasks SHALL share a single PlaybookContent row

---

### Requirement: Canonical Ansible Operation History UI

The web UI SHALL expose launch and execution history only as canonical operations through `/ansible/operations` and `/ansible/operations/:id`. A retained `PlaybookRun` hierarchy MAY continue to serve internal ingestion, audit, retention, and SRQL requirements, but it SHALL NOT create a second user-facing index, detail page, launch result, or device-history model.

#### Scenario: Successful launch opens canonical evidence

- **GIVEN** an authorized operator submits a hardened Ansible launch
- **WHEN** the immutable operation, child execution, and exact target evidence are persisted
- **THEN** the UI SHALL navigate to `/ansible/operations/:id`
- **AND** the detail page SHALL show the initiating actor, controller and inventory scope, content revision, dispatch state, exact targets, diagnostics, and active holds available to the actor

#### Scenario: Operator lists execution history

- **GIVEN** an operator with `ansible.runs.view`
- **WHEN** they navigate to `/ansible/operations`
- **THEN** the UI SHALL list canonical operations and link each row to `/ansible/operations/:id`
- **AND** the UI SHALL NOT expose a separate `PlaybookRun` index or detail page

#### Scenario: Device detail shows operation history

- **GIVEN** an AWX-managed device with canonical operation history
- **WHEN** an authorized operator views the device detail page
- **THEN** the Ansible panel SHALL list only canonical operations that targeted the device
- **AND** each evidence link SHALL target `/ansible/operations/:id`
- **AND** retained `PlaybookRunTarget` rows SHALL NOT affect the panel's history or empty state

---

### Requirement: Event Ingestion Watchdog

The system SHALL run an AshOban watchdog that transitions any `PlaybookRun` in a non-terminal state past `2 × job_template.timeout` (or a 1-hour fallback when timeout is unknown) to `unreachable` with a diagnostic recording the watchdog reason.

#### Scenario: AWX becomes unreachable mid-run

- **GIVEN** a run in `running` and the agent's `awx.fetch_job` calls returning errors for over an hour
- **WHEN** the watchdog runs
- **THEN** the run SHALL transition to `unreachable`
- **AND** a diagnostic SHALL record "watchdog: AWX unreachable for >Xs"
- **AND** if AWX recovers later, late event chunks SHALL still persist but the run state SHALL NOT change

---

### Requirement: Pulse-Based Event Ingestion and Watermark Resume

The system SHALL ingest AWX job events via per-controller `RunPulseWorker` ticks dispatched through `AgentCommandBus`. On each tick, the worker SHALL identify non-terminal `PlaybookRun` rows for its controller and, if any exist, dispatch one `awx.fetch_events_for_jobs` command carrying their `(awx_job_id, last_event_id)` watermarks. The system SHALL persist returned events idempotently, advance per-run watermarks, and run state-machine transitions in the same transaction. The system SHALL NOT maintain long-lived streams or per-run streaming assignments.

#### Scenario: Pulse worker batches multiple active runs in one command

- **GIVEN** three non-terminal `PlaybookRun`s for one controller with watermarks 10, 25, 50
- **WHEN** the RunPulseWorker ticks
- **THEN** the system SHALL dispatch one `awx.fetch_events_for_jobs` command with all three (job_id, since_id) pairs
- **AND** the plugin's response SHALL include events for all three jobs keyed by job_id
- **AND** Elixir SHALL persist the events and advance each run's `last_event_id` accordingly

#### Scenario: Pulse skips when no active runs

- **GIVEN** a controller with zero non-terminal runs
- **WHEN** the RunPulseWorker ticks
- **THEN** the system SHALL NOT dispatch any command to the agent
- **AND** SHALL return without contacting AWX

#### Scenario: Agent disconnect resumes seamlessly on next tick

- **GIVEN** a `PlaybookRun` in `running` with `last_event_id = 142` whose agent disconnects from the gateway
- **WHEN** subsequent RunPulseWorker ticks fail to reach the agent
- **THEN** the worker SHALL retry with backoff, persisting nothing
- **AND** when the agent reconnects, the next tick SHALL read `last_event_id = 142` from the DB and dispatch `awx.fetch_events_for_jobs` with `since_id = 142`
- **AND** events ≤142 SHALL NOT be re-persisted
- **AND** events >142 SHALL be persisted as if the disconnect had not happened

---

### Requirement: Multi-Controller Plugin Instance

A single `awx` plugin instance on a single agent SHALL serve any number of `AnsibleController` records reachable from that agent's network. The plugin SHALL hold no per-controller static state; each `CommandRequest` SHALL carry its own credential broker grant identifying the target controller's base_url and API token. Adding or removing a controller SHALL NOT require redeploying or reassigning the plugin.

#### Scenario: One agent serves two controllers

- **GIVEN** two `AnsibleController` records both pointing at agent A
- **WHEN** Elixir issues `awx.ping` against each in turn
- **THEN** the same plugin instance on agent A SHALL handle both calls
- **AND** each call SHALL use the credential broker grant carried in its own `CommandRequest`

---

### Requirement: SRQL Resource Aliases

The system SHALL expose `ansible_runs`, `ansible_playbooks`, and `ansible_controllers` as SRQL resource aliases routed through the existing AshAdapter, so operators can query Ansible data alongside other ServiceRadar entities.

#### Scenario: Operator queries failed runs for a device in the last day

- **GIVEN** an operator with `ansible.runs.view` permission
- **WHEN** they execute `SHOW ansible_runs WHERE device_uid = "sr:abc" AND status = "failed" SINCE 24h`
- **THEN** the AshAdapter SHALL resolve the alias to the `PlaybookRun` resource
- **AND** SHALL return only runs the actor's tenant policies allow

---

### Requirement: NATS Event Emission

On every `PlaybookRun` state transition and on each persisted `PlaybookTaskResult`, the system SHALL publish an event to NATS JetStream using subjects under `serviceradar.ansible.*` via the existing `EventBatcher`. Events SHALL conform to the platform's existing event envelope and SHALL NOT contain secrets.

#### Scenario: A run transitions from running to succeeded

- **WHEN** the ingestor transitions the run to `succeeded`
- **THEN** the system SHALL publish an event on `serviceradar.ansible.run.completed` with run_id, device_uid, playbook_id, started_at, ended_at, summary
- **AND** the event payload SHALL NOT contain the AWX api_token, deploy tokens, or any field marked sensitive in the resource definitions

---

### Requirement: AWX WASM Plugin (Network Bridge)

The system SHALL ship a single `awx` WASM plugin built with `serviceradar-sdk-go` that runs on a ServiceRadar agent inside the customer network and serves as the network bridge between Elixir orchestration and the AWX/AAP REST API. The plugin SHALL expose two entrypoints; neither SHALL maintain long-lived connections.

1. A **request-response** entrypoint (`run_check`) that handles AWX REST verbs dispatched as `CommandRequest`s by Elixir's `AwxClient` via `AgentCommandBus`. Supported verbs: `awx.ping`, `awx.list_inventories`, `awx.list_hosts`, `awx.list_projects`, `awx.list_templates`, `awx.fetch_template`, `awx.launch_job`, `awx.fetch_job`, `awx.cancel_job`, `awx.fetch_events_for_jobs`. Each verb SHALL produce one `CommandResult` whose `payload_json` carries a typed success or error payload. List verbs SHALL handle pagination internally. The bulk `awx.fetch_events_for_jobs` verb SHALL accept a list of `(awx_job_id, since_id)` pairs, make one HTTP call per job within the same agent invocation, and return events keyed by `awx_job_id`.

2. A **scheduled** entrypoint (`inventory_sync`) that walks each configured controller's inventories and hosts, builds a `sdk.NewDeviceDiscovery("awx")` aggregate, and attaches it to the plugin result via `result.WithDeviceDiscovery(...)`. The existing agent → gateway → DIRE pipeline SHALL carry the records the rest of the way. The plugin SHALL NOT push records into Elixir via any other path.

The plugin SHALL resolve credential broker grants from command payloads (for `run_check`) and from assignment configuration (for `inventory_sync`) to obtain AWX `base_url` and API token per controller. The plugin SHALL NEVER accept plaintext API tokens from Elixir.

#### Scenario: Elixir dispatches `awx.ping` for controller health

- **GIVEN** a registered controller with a connected agent
- **WHEN** `AwxClient.ping(controller)` is called
- **THEN** Elixir SHALL mint a credential broker grant and dispatch a `CommandRequest{type: "awx.ping", payload: {grant}}`
- **AND** the agent's `awx` plugin SHALL resolve the grant, GET `/api/v2/ping/`, and return a `CommandResult` whose payload includes status, version, and instance-group worker counts
- **AND** Elixir SHALL persist the result on the controller's `last_health_at` / `status`

#### Scenario: Bulk fetch of events for multiple active jobs

- **GIVEN** three non-terminal `PlaybookRun`s for one controller with `(job_id, last_event_id)` of `(7331, 0)`, `(7332, 50)`, `(7333, 200)`
- **WHEN** RunPulseWorker dispatches `awx.fetch_events_for_jobs` with all three pairs
- **THEN** the plugin SHALL make three HTTP calls to AWX (one per job), gather their new events, and return one `CommandResult` whose payload maps each `awx_job_id` to its events
- **AND** Elixir SHALL persist events for all three runs in one transactional pass

#### Scenario: Inventory sync emits DeviceDiscovery aggregate

- **GIVEN** an agent assigned the `inventory_sync` entrypoint with a list of two controllers reachable from this agent
- **WHEN** the scheduled invocation runs
- **THEN** the plugin SHALL list every inventory + host across both controllers
- **AND** SHALL build a single `sdk.NewDeviceDiscovery("awx")` aggregate carrying every host with controller / inventory / host_id metadata
- **AND** SHALL attach the aggregate via `result.WithDeviceDiscovery(...)` so the existing agent → gateway → DIRE pipeline ingests the records

#### Scenario: Plugin dispatched against an unreachable controller

- **GIVEN** a controller whose `base_url` is unreachable from the agent
- **WHEN** Elixir dispatches `awx.ping`
- **THEN** the plugin SHALL return a `CommandResult` whose payload describes a network error with operator-safe summary
- **AND** SHALL NOT block other plugin commands from running

---

### Requirement: Operator-Safe Error Surfaces

All AWX API errors and git sync errors surfaced to the LiveView SHALL be normalized into typed errors with operator-safe summaries. Stack traces, raw response bodies, and credentials SHALL never appear in the UI or NATS events.

#### Scenario: AWX returns a 401 on launch

- **GIVEN** an AwxClient call that receives a 401
- **WHEN** the error propagates to the launch LiveView
- **THEN** the operator SHALL see a normalized message such as "AWX rejected the request: authentication failed — check controller token"
- **AND** the raw response body SHALL NOT be rendered

---

### Requirement: AWX Inventory as a Plugin-Emitted Discovery Source

The system SHALL discover AWX inventory hosts via the `awx` plugin's `inventory_sync` scheduled entrypoint, which emits `DeviceDiscovery` aggregates with `discovery_source = "awx"` into the existing agent → gateway → DIRE pipeline (the same pipeline that proxmox-inventory and other discovery plugins use today). DIRE SHALL merge AWX host records with records from other discovery sources, and `Device.ansible_managed` / `Device.ansible_inventory_ref` SHALL be derived from the merged record set. The system SHALL NOT operate a separate Elixir-side worker that pulls inventory via verb commands. The system SHALL NOT expose a manual "mark Ansible-managed" action.

#### Scenario: Plugin emits AWX hosts; DIRE merges with existing devices

- **GIVEN** an AWX host with `name = "web01.example.com"` whose `variables.ansible_host = "10.0.0.5"` AND a ServiceRadar Device with hostname `web01.example.com` and ip `10.0.0.5`
- **WHEN** the `awx` plugin's `inventory_sync` entrypoint runs on schedule
- **THEN** the plugin SHALL emit a DeviceDiscovery aggregate including this host
- **AND** DIRE SHALL merge the AWX host into the existing device with `awx` added to `discovery_sources`
- **AND** `ansible_managed` SHALL be `true`
- **AND** `ansible_inventory_ref` SHALL contain the controller_id, inventory_id, host_id, and host_name

#### Scenario: AWX host overlaps with proxmox-discovered device

- **GIVEN** a device already discovered via the proxmox integration AND the same logical host appearing in AWX inventory (because AWX uses the proxmox community ansible inventory plugin)
- **WHEN** both plugin inventory entrypoints run
- **THEN** DIRE SHALL merge the records into a single device with `discovery_sources` containing both `proxmox` and `awx`
- **AND** the device SHALL have both proxmox metadata and `ansible_inventory_ref` populated

#### Scenario: AWX host disappears

- **GIVEN** a device previously matched to an AWX host that has been removed from AWX inventory
- **WHEN** the next `inventory_sync` invocation no longer emits the host
- **THEN** DIRE SHALL drop `awx` from the device's `discovery_sources`
- **AND** the device SHALL have `ansible_managed = false`
- **AND** `ansible_inventory_ref` SHALL be cleared
- **AND** historical `PlaybookRun` rows referencing the device SHALL be retained for audit

#### Scenario: AWX host that DIRE cannot match

- **GIVEN** an AWX host whose name and `ansible_host` do not match any ServiceRadar device
- **WHEN** the plugin emits the host as part of its DeviceDiscovery aggregate
- **THEN** the host SHALL appear in the `/settings/ansible` "needs review" list (sourced from DIRE's existing unmatched-record surface)
- **AND** an operator SHALL be able to manually link it to a device or trigger DIRE creation of a new device record

---

### Requirement: OCSF Event Projection for Retained Playbook Activity

For the retained internal `PlaybookRun` ingestion path, the system SHALL emit OCSF-shaped events for each task result and each internal run state transition, written directly to the existing observability events stream (the same stream that backs the universal log viewer). Events SHALL NOT be routed through a separate OTEL collector. The OCSF event SHALL carry sufficient internal-run context (`run_id`, target `device_uid`, `controller_id`, playbook name, status, summary) to be useful in a log search without joining back to the structured tables. This requirement SHALL NOT imply that a hardened `AutomationOperation` created by the interactive launch path also creates a `PlaybookRun` or inherits an unpersisted correlation.

#### Scenario: Task result generates an OCSF event

- **GIVEN** a running playbook reports a task succeeded on a host
- **WHEN** EventIngestor persists the `PlaybookTaskResult`
- **THEN** the system SHALL also write an OCSF-shaped event to the observability events stream
- **AND** the event SHALL be searchable in the existing log viewer by `device_uid`, by `playbook_run_id`, and by `playbook_name`

#### Scenario: Operator filters log viewer to ansible activity

- **GIVEN** the log viewer is open with no filters
- **WHEN** the operator filters by event class (or whatever attribute identifies ansible activity)
- **THEN** the operator SHALL see the projected ansible task events alongside other system signals
- **AND** retained events SHALL remain searchable without linking to a retired execution-history route
- **AND** the UI SHALL link an event to `/ansible/operations/:id` only when an explicit persisted canonical-operation correlation exists

---

### Requirement: AshPaperTrail Audit on Controllers, Repositories, and Retained Runs

The system SHALL track changes to `AnsibleController`, `PlaybookRepository`, and retained `PlaybookRun` resources via the AshPaperTrail extension. Current create/update actions SHALL NOT accept raw requested variables, and audit/PaperTrail records SHALL NOT introduce secret-capable or arbitrary `extra_vars`. Hardened interactive launch evidence SHALL live on the canonical operation/execution/target resources rather than requiring a new `PlaybookRun` version.

#### Scenario: Retained internal run attribution is audited without raw inputs

- **GIVEN** an internal `PlaybookRun` exists with actor, playbook, and target attribution
- **WHEN** AshPaperTrail records a retained lifecycle action
- **THEN** the version SHALL preserve the permitted attribution and action metadata
- **AND** SHALL NOT store browser-supplied raw variables or reusable secret values
- **AND** the audit record SHALL be queryable via SRQL alongside other versioned resources

#### Scenario: State transitions appear in audit history

- **GIVEN** a `PlaybookRun` that has progressed `pending → launching → running → succeeded`
- **WHEN** an operator inspects the run's audit history
- **THEN** SHALL see four state-transition entries with timestamps and triggering actor (operator vs. system worker)

---

### Requirement: Configurable Run Retention

The system SHALL support operator-configurable retention for run data via two values in `helm/serviceradar/values.yaml` and `docker-compose.yml`: `ansible.retention.run_detail_days` (how long the full task hierarchy is retained; default `90`) and `ansible.retention.run_summary_days` (how long `PlaybookRun` and `PlaybookRunTarget` rows are retained; default `null`, meaning forever). A `RetentionWorker` SHALL sweep daily, deleting rows past the configured thresholds. Runs accessed (read or written) within the previous hour SHALL be excluded from any sweep.

#### Scenario: Detail past threshold is pruned

- **GIVEN** `run_detail_days = 30` and a `PlaybookRun` from 45 days ago that has not been viewed recently
- **WHEN** the RetentionWorker runs
- **THEN** its `PlaybookPlay`, `PlaybookTask`, `PlaybookTaskResult`, and dereferenced `PlaybookContent` rows SHALL be deleted
- **AND** the `PlaybookRun` row + its `PlaybookRunTarget`s SHALL be retained (per default `run_summary_days = null`)
- **AND** pruning the internal hierarchy SHALL NOT remove or alter canonical immutable operation evidence

#### Scenario: Recently-viewed run is excluded from sweep

- **GIVEN** a run from 100 days ago that an operator viewed 30 minutes ago, with `run_detail_days = 90`
- **WHEN** the RetentionWorker runs
- **THEN** the run's detail SHALL NOT be deleted in this sweep
- **AND** SHALL be eligible on a subsequent sweep once the access window has passed

#### Scenario: Summary retention bounded

- **GIVEN** `run_summary_days = 365` and a `PlaybookRun` from 400 days ago
- **WHEN** the RetentionWorker runs
- **THEN** the entire run record SHALL be deleted (PlaybookRun, PlaybookRunTargets, any remaining detail)

---

### Requirement: Retained Schedule Records Remain Fail-Closed

The system MAY retain `PlaybookSchedule` resources, PaperTrail versions, relationships, and evaluator registration for migration and audit compatibility. Retained rows SHALL default disabled, current create/update actions SHALL NOT accept raw requested variables, and enablement SHALL fail until a separately approved immutable execution-delegation path exists. The web UI SHALL NOT expose schedule creation, editing, enable/disable, deletion, launch affordances, or a separate schedule execution history. The retained evaluator and legacy launcher SHALL NOT create a `PlaybookRun`, `AutomationOperation`, or AWX launch command from those rows.

#### Scenario: Retained schedule is evaluated

- **GIVEN** a retained disabled schedule row
- **WHEN** `ScheduleEvaluatorWorker` evaluates due work
- **THEN** it SHALL NOT create an internal run, canonical operation, or AWX launch command

#### Scenario: Schedule enablement is requested

- **GIVEN** an actor with the retained `ansible.schedules.manage` compatibility permission
- **WHEN** enablement is requested without an approved immutable execution delegation
- **THEN** the system SHALL reject the request
- **AND** the schedule SHALL remain disabled

#### Scenario: Operator opens Ansible settings

- **GIVEN** an authenticated operator
- **WHEN** the operator views the Ansible settings page
- **THEN** the UI SHALL NOT expose schedule controls or a schedule execution-history surface

#### Scenario: Future delegated schedule execution is proposed

- **WHEN** a future change introduces scheduled execution
- **THEN** it SHALL require an expiring and revocable immutable delegation plus fire-time reauthorization
- **AND** accept only approved typed non-secret inputs
- **AND** persist user-facing evidence as a canonical `AutomationOperation`
