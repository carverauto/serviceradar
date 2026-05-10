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

The system SHALL parse each playbook YAML file to extract: `name`, `description` (from a leading comment block or `description` key), declared variables (top-level `vars`), `vars_prompt` definitions, `tags`, and `hosts` pattern. Parsed metadata SHALL be stored on the `Playbook` Ash resource and SHALL drive the launch dialog UI.

#### Scenario: Playbook declares vars_prompt entries

- **GIVEN** a playbook with `vars_prompt: [{name: "version", prompt: "Target version"}]`
- **WHEN** an operator opens the launch dialog for that playbook
- **THEN** the dialog SHALL render a typed input labeled "Target version"
- **AND** the entered value SHALL be passed to AWX as part of `extra_vars`

#### Scenario: Operator overrides extra_vars with raw YAML

- **GIVEN** an operator launching a playbook with raw-YAML override toggled on
- **WHEN** the operator submits valid YAML in the override field
- **THEN** the system SHALL merge the override over the prompt-driven extra_vars
- **AND** invalid YAML SHALL block submission with a parse error

---

### Requirement: AWX Job Template Binding (git-sourced playbooks)

A `git`-sourced `Playbook` catalog entry SHALL carry an optional `awx_job_template_id`. The system SHALL allow operators to launch a `git`-sourced playbook only if it is bound to a valid AWX job template; unbound playbooks SHALL appear in the catalog with a clear "AWX template binding required" indicator and SHALL NOT be selectable in the launch flow. `awx`-sourced playbooks are launchable by definition (the catalog entry itself is the AWX template) and SHALL NOT carry a separate binding.

#### Scenario: Operator attempts to launch an unbound git-sourced playbook

- **GIVEN** a `git`-sourced Playbook with no `awx_job_template_id`
- **WHEN** the operator opens the launch flow
- **THEN** that playbook SHALL NOT appear in the selectable list
- **AND** the catalog browser SHALL show the playbook with an "AWX template binding required" warning

#### Scenario: AWX-sourced playbook is launchable without separate binding

- **GIVEN** an `awx`-sourced Playbook
- **WHEN** the operator opens the launch flow
- **THEN** that playbook SHALL be selectable
- **AND** the launch path SHALL use the playbook's source `awx_job_template_id` directly

#### Scenario: AWX job template referenced by binding has been deleted

- **GIVEN** a Playbook bound to a job template that no longer exists in AWX
- **WHEN** an operator attempts to launch
- **THEN** the system SHALL detect the missing template, mark the binding as invalid on the Playbook, and reject the launch with an operator-safe error message
- **AND** the catalog UI SHALL surface the broken-binding state

---

### Requirement: Run Lifecycle State Machine

`PlaybookRun` SHALL be implemented as an Ash State Machine with states `pending`, `launching`, `running`, `succeeded`, `partial`, `failed`, `unreachable`, `canceled`. Allowed transitions SHALL be: `pending → launching`, `launching → running | failed | unreachable`, `running → succeeded | partial | failed | unreachable | canceled`. Terminal states SHALL NOT transition further. `partial` SHALL be reached only when `PlaybookRunTarget` outcomes are mixed (some succeeded, some failed); `failed` SHALL be reached when *every* `PlaybookRunTarget` failed.

#### Scenario: Successful run progresses through states

- **GIVEN** an operator triggers a launch against a single device
- **WHEN** the run is created
- **THEN** the run SHALL be in `pending`
- **AND** the launch worker SHALL transition it to `launching` after creating the AWX job
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

- **GIVEN** an operator with `ansible.runs.cancel` permission and a run in `running`
- **WHEN** the operator clicks Cancel
- **THEN** the system SHALL dispatch `awx.cancel_job` via the bus
- **AND** transition the run to `canceled` once AWX confirms

---

### Requirement: Run Launch Authorization

The system SHALL only allow a run launch when ALL of the following hold: the actor has `ansible.runs.launch` permission, every selected target device has `ansible_managed = true`, every selected target device has a populated `ansible_inventory_ref` whose `controller_id` resolves to a single common `AnsibleController` across all selected devices, the selected playbook is launchable (AWX-sourced, or git-sourced with a valid AWX template binding), and the agent referenced by the controller is currently connected to its agent-gateway.

#### Scenario: Operator launches against an unmanaged device

- **GIVEN** a device with `ansible_managed = false` selected as a target
- **WHEN** an operator opens the Device Actions modal and chooses Run Playbook
- **THEN** the unmanaged device SHALL be flagged in the target list as ineligible
- **AND** the launch button SHALL be disabled until the device is removed from the selection or the selection is changed

#### Scenario: Multi-device selection spans multiple controllers

- **GIVEN** five selected devices where three are managed by Controller A and two by Controller B
- **WHEN** the operator opens Run Playbook
- **THEN** the system SHALL refuse to proceed with the mixed selection
- **AND** SHALL surface an operator-safe message explaining that the selection must share a single controller
- **AND** SHALL offer to narrow the selection to one controller

#### Scenario: Controller's agent is offline at launch time

- **GIVEN** an AnsibleController whose agent is not currently connected to the gateway
- **WHEN** an operator with `ansible.runs.launch` attempts to launch
- **THEN** the system SHALL reject the launch with an operator-safe error explaining the agent is unreachable
- **AND** SHALL NOT create a `PlaybookRun` row in `pending`

---

### Requirement: Run Hierarchy Persistence

For every launched run the system SHALL persist a hierarchy of `PlaybookRun → PlaybookRunTarget` (one per targeted device, joining ServiceRadar device_uid to AWX host_id) and `PlaybookRun → PlaybookPlay → PlaybookTask → PlaybookTaskResult`. Each `PlaybookTaskResult` SHALL reference both its `PlaybookTask` and its `PlaybookRunTarget`. Per-task stdout/stderr blobs SHALL be deduplicated by sha256 hash via a `PlaybookContent` table to bound storage growth across repeated runs.

#### Scenario: A multi-device run with multiple plays

- **GIVEN** a successful run with 2 plays, each containing 5 tasks across 3 selected devices
- **WHEN** the run completes
- **THEN** the database SHALL contain 1 PlaybookRun, 3 PlaybookRunTargets, 2 PlaybookPlays, 10 PlaybookTasks, up to 30 PlaybookTaskResults each linked to its target
- **AND** identical task stdout across tasks SHALL share a single PlaybookContent row

#### Scenario: Run streams to LiveView in near real time

- **GIVEN** an operator viewing `/ansible/runs/:id` for an in-progress run
- **WHEN** the ingestor persists a new task result
- **THEN** the LiveView SHALL receive a PubSub broadcast within 2 seconds
- **AND** the new task SHALL appear without a page reload, attributed to its target device in the per-target table

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

### Requirement: OCSF Event Projection for Playbook Activity

In addition to the structured `PlaybookTaskResult` rows, the system SHALL emit OCSF-shaped events for each task result and each `PlaybookRun` state transition, written directly to the existing observability events stream (the same stream that backs the universal log viewer). Events SHALL NOT be routed through a separate OTEL collector. The OCSF event SHALL carry sufficient context (run_id, target device_uid, controller_id, playbook name, status, summary) to be useful in a log search without joining back to the structured tables.

#### Scenario: Task result generates an OCSF event

- **GIVEN** a running playbook reports a task succeeded on a host
- **WHEN** EventIngestor persists the `PlaybookTaskResult`
- **THEN** the system SHALL also write an OCSF-shaped event to the observability events stream
- **AND** the event SHALL be searchable in the existing log viewer by `device_uid`, by `playbook_run_id`, and by `playbook_name`

#### Scenario: Operator filters log viewer to ansible activity

- **GIVEN** the log viewer is open with no filters
- **WHEN** the operator filters by event class (or whatever attribute identifies ansible activity)
- **THEN** the operator SHALL see the projected ansible task events alongside other system signals
- **AND** SHALL be able to click through from an event to the corresponding `/ansible/runs/:id` detail page

---

### Requirement: AshPaperTrail Audit on Controllers, Repositories, and Runs

The system SHALL track changes to `AnsibleController`, `PlaybookRepository`, and `PlaybookRun` resources via the AshPaperTrail extension. Audit history SHALL include who launched a run with what extra_vars and target list, who canceled a run, who registered or rotated a controller, and the full state-machine transition history with timestamps and triggering actor.

#### Scenario: Run launch is audited

- **GIVEN** an operator launches a playbook against three devices
- **WHEN** the `PlaybookRun` is created
- **THEN** AshPaperTrail SHALL record the create with the actor's id, the playbook id, the target device_uids, and the requested extra_vars
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
- **AND** the run detail page SHALL display a banner indicating the detail has been pruned

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

### Requirement: Scheduled and Recurring Playbook Runs

The system SHALL support `PlaybookSchedule` resources that pair a launchable `Playbook`, a list of target devices (subject to the same single-controller and ansible-managed rules as ad-hoc runs), optional `extra_vars`, a standard 5-field cron expression, and a timezone. An AshOban `ScheduleEvaluatorWorker` SHALL evaluate enabled schedules at their cadence and create a `PlaybookRun` exactly as if a human had launched it through the Device Actions modal, with `PlaybookRun.schedule_id` set to the source schedule. Operators with `ansible.schedules.manage` permission SHALL be able to create, update, enable / disable, and delete schedules.

#### Scenario: Schedule fires and creates a run

- **GIVEN** an enabled schedule `cron = "0 3 * * *"` in `Europe/London` for playbook P targeting devices D1 and D2
- **WHEN** the wall clock reaches 03:00 London time
- **THEN** the ScheduleEvaluatorWorker SHALL create a new `PlaybookRun` linked to playbook P with `schedule_id` referencing the schedule
- **AND** SHALL create `PlaybookRunTarget` rows for D1 and D2
- **AND** SHALL launch the run via `AwxClient.launch_job` exactly as the modal would
- **AND** SHALL update `last_evaluated_at`, `last_run_id`, and `next_run_at` on the schedule

#### Scenario: Concurrent overlap with previous run, allow_concurrent = false

- **GIVEN** a schedule whose previous `PlaybookRun` is still in `running` and `allow_concurrent = false`
- **WHEN** the next cron fire occurs
- **THEN** the worker SHALL NOT create a new `PlaybookRun`
- **AND** SHALL record `skipped_overlap` with timestamp on the schedule's audit trail
- **AND** SHALL surface a "skipped (still running)" badge on the schedule's detail page

#### Scenario: allow_concurrent = true

- **GIVEN** a schedule with `allow_concurrent = true` whose previous `PlaybookRun` is still `running`
- **WHEN** the next cron fire occurs
- **THEN** the worker SHALL create and launch a new `PlaybookRun` regardless of the previous run's state

#### Scenario: Schedule disabled

- **GIVEN** an enabled schedule
- **WHEN** an operator with `ansible.schedules.manage` disables it
- **THEN** the worker SHALL NOT fire it on subsequent ticks until re-enabled
- **AND** the schedule's audit trail SHALL record the disable event

#### Scenario: Schedule with ineligible targets

- **GIVEN** a schedule whose target_device_uids include a device that has since had `ansible_managed = false` set (e.g. removed from AWX inventory)
- **WHEN** the schedule fires
- **THEN** the worker SHALL skip the firing
- **AND** SHALL record a diagnostic on the schedule's audit trail naming the ineligible device(s)
- **AND** SHALL emit an OCSF event so operators can be alerted
