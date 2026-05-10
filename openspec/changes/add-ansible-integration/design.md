## Context

ServiceRadar already has a rich device inventory (Ash + OCSF schema), an event/metric pipeline (NATS JetStream → EventBatcher → observability tables), an Ash-first data layer with AshOban (jobs), AshCloak (encryption), and Ash State Machine available, and — critically for this proposal — a `core → agent-gateway → agent → WASM plugin` network path that's the *only* way to reach customer-private resources. AWX/AAP almost always lives in the customer's private network alongside their inventory; ServiceRadar core (SaaS) cannot dial it directly. The agent must.

The relevant primitives that already exist:

- **`AgentCommandBus.dispatch/4`** (`elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex:24`) sends typed `CommandRequest` protos to an agent over the bidirectional `ControlStream` and receives one `CommandResult` per command. Used today by patterns like `proxmox.credential_test`, `mtr.run`, `mapper.run_job`.
- **PluginManager streaming mode** (`go/pkg/agent/plugin_runtime.go:181`) supports long-lived plugin assignments that emit a stream of chunks via `StreamStatus` (e.g. `stream_camera`, proxmox console). The host bridges chunks to the gateway and on into Elixir.
- **Credential broker grants** (`elixir/serviceradar_core/lib/serviceradar/credentials/`) — encrypted, short-lived references that travel in command payloads. Plugins resolve them at the edge to obtain target URLs and tokens. This is the existing pattern for cross-network secret hand-off; it replaces my earlier "store the AWX token via AshCloak on the resource" idea.
- **Multi-tenancy** is handled at the deployment layer, not the resource layer: each tenant runs their own stack (Elixir, agent-gateway, agents) in their own k8s namespace, sharing only Postgres (separate schemas) and NATS JetStream (subject-isolated). Resources do *not* need `tenant_id` columns for AWX-related work.

ARA is being prototyped in the cluster to capture playbook telemetry, but it duplicates a UI, a schema, and a Python service — none of which fit the ServiceRadar architecture, and none of which integrate with our RBAC, SRQL, or observability stack.

The user's primary use case is *"go into a device and run a playbook on it"* with full visibility into the run. The execution backend is **AWX/AAP** (REST API, k8s/Docker/VM-deployable, already vault-aware, lives in the customer network). The catalog source is **git** (operators want one source of truth for playbooks, decoupled from AWX project config). Scope is one cohesive proposal, on-demand execution, single-device-at-a-time UI.

## Goals / Non-Goals

### Goals
- Operators can mark a device as Ansible-managed and link it to an AWX inventory host.
- Operators can register git repos as the canonical playbook catalog; metadata is parsed and indexed.
- Operators can launch a playbook against a single device from its detail page in two clicks.
- A run produces a queryable hierarchical record (run → plays → tasks → results × hosts) replacing ARA's role.
- Runs stream live to the LiveView via PubSub and are tailable from `/ansible/runs/:id`.
- All authorization flows through the existing RBAC catalog; no bespoke permission system.
- Run state is encoded as an Ash State Machine, so transitions are auditable and can't go backward.

### Non-Goals (v1)
- Pushing devices into AWX inventory from ServiceRadar (we only *link* to existing AWX hosts).
- Storing SSH keys, become passwords, or vault passwords (AWX owns these).
- Direct `ansible-playbook` execution by a ServiceRadar agent (AWX-only in v1).
- Scheduled / recurring runs from the UI (AshOban could do it; deferred).
- Multi-device fan-out from the UI (operators can script via API in v1).
- A new general-purpose "automation" framework — this proposal is Ansible-specific. If a second backend (e.g., direct exec) lands later, we'll generalize then.

## Decisions

### Decision 1: AWX is the execution backend; we never shell out to `ansible-playbook` in v1.

**Why:** AWX already solves credential vaulting, SSH-key isolation, executor scheduling, and inventory sync. Operators who run Ansible at any scale already have AWX or are migrating toward it. Building a parallel execution path in ServiceRadar duplicates a hard, security-sensitive system.

**Alternatives considered:**
- *Direct exec from a ServiceRadar agent + custom callback plugin (ARA's model).* Rejected for v1: it forces ServiceRadar into the credential-storage business and re-implements AWX's executor/inventory/vault. Could be a v2 plugin if there's demand from operators without AWX.
- *Use `ansible-runner` library directly.* Same drawbacks as direct exec, plus a Python runtime in our agent. Rejected.

### Decision 2: Catalog has multiple source types — git AND AWX — and operators choose.

The `Playbook` resource is polymorphic. It carries a `source_type` discriminator with two values in v1:

- `git` — ServiceRadar clones a registered `PlaybookRepository`, parses YAML, derives metadata (name, description, declared `vars_prompt`, top-level vars, tags, hosts pattern). Variable prompts come from `vars_prompt` blocks.
- `awx` — ServiceRadar pulls AWX Job Templates via `awx.list_templates`, treats each Job Template as a catalog entry, and uses AWX's `survey_spec` for variable prompts. The Job Template binding is implicit (the catalog entry *is* a Job Template).

Both sources can coexist. An operator who has organized their playbooks as a git repo gets that catalog. An operator who has invested in AWX project + template configuration gets that catalog. An operator with both gets both — the same playbook may appear twice if discoverable via both sources, with a small badge on each catalog entry identifying its origin.

For execution: a `git`-sourced playbook still requires an `awx_job_template_id` binding to be launchable (operator must point it at a corresponding AWX Job Template). An `awx`-sourced playbook is launchable by definition.

**Why:** Per the user's direction. Reality is that some operators standardize on git-as-source-of-truth, others standardize on AWX as their automation control plane, and many do both. We support all three shapes without forcing operators to migrate.

**Alternatives considered:**
- *Git-only.* Forces operators with mature AWX setups to re-register everything as a git repo. Rejected.
- *AWX-only mirror.* Forces operators who don't yet have AWX Project sync configured to set it up. Rejected.
- *Polymorphic via STI subclassing in Ash.* Considered; too much ceremony for two source types. Single resource with a `source_type` enum + nullable `repository_id` / `controller_id` + jsonb `source_metadata` is fine.

### Decision 3: WASM plugin is the network bridge to AWX, controller-agnostic, with no long-lived streams.

AWX lives in the customer network. ServiceRadar core (SaaS) has no route to it. The only thing that does is the agent. Therefore *every* AWX REST call — ping, list inventories/hosts/projects/templates, launch, fetch, fetch-events-for-jobs, cancel — flows through the WASM plugin. Elixir orchestrates state, persistence, and UI; the plugin is the dumb-but-trusted HTTP arm.

**Multi-controller per plugin instance.** The plugin holds *no* per-controller static state. Each `CommandRequest` carries its own credential broker grant (which resolves to base_url + API token at the edge), so a single plugin instance on a single agent can serve any number of AWX controllers reachable from that agent's network. Adding a second controller is just another `AnsibleController` row in Elixir — no plugin reassignment, no redeploy.

**Two execution modes, no long-lived streams:**

| Plugin entrypoint | Mode | Purpose |
|---|---|---|
| `run_check` (on-demand via `AgentCommandBus`) | One `CommandRequest` → one `CommandResult` | All AWX REST verbs: `awx.ping`, `awx.list_inventories`, `awx.list_hosts(inventory_id)`, `awx.list_projects`, `awx.list_templates`, `awx.fetch_template`, `awx.launch_job`, `awx.fetch_job`, `awx.cancel_job`, `awx.fetch_events_for_jobs([(job_id, since_id), ...])`. Each verb makes one HTTP call (or one paginated walk) to AWX. The bulk `fetch_events_for_jobs` verb takes a list of (job_id, watermark) pairs and returns new events for all of them in one round-trip — this is what drives the run-event tail. |
| `inventory_sync` (scheduled assignment) | One scheduled invocation → emits a `DeviceDiscovery` aggregate via `result.WithDeviceDiscovery(...)` | Mirrors the proxmox-inventory plugin pattern (`go/cmd/wasm-plugins/proxmox/main.go:343,433`). Plugin lists every inventory + host across configured controllers, builds a `DeviceDiscovery` with `discovery_source = "awx"`, attaches it to the result, and the existing agent → gateway → DIRE pipeline carries the records the rest of the way. **No new ingestion plumbing on the Elixir side.** |

Component split:

| Component | Role |
|---|---|
| `Serviceradar.Automation.Ansible.AwxClient` (Elixir) | Issues `AgentCommandBus.dispatch` for each AWX REST verb. Knows the verb names and JSON shapes. **Never speaks HTTP itself.** Returns typed errors. |
| `Serviceradar.Automation.Ansible.RunPulseWorker` (AshOban, one job per controller) | Ticks every N seconds (default 2s, configurable). On each tick: list non-terminal `PlaybookRun`s for this controller; if any, dispatch one `awx.fetch_events_for_jobs` command with their `(job_id, last_event_id)` pairs; on response, persist new events, advance watermarks, run state-machine transitions. If no active runs, skip the tick. |
| `Serviceradar.Automation.Ansible.PlaybookRun` (Ash + State Machine) | Authoritative state for a run. State transitions driven by RunPulseWorker and by `awx.fetch_job` results. |
| `cmd/wasm-plugins/awx/` (Go, built with `serviceradar-sdk-go`) | Two entrypoints — `run_check` for all on-demand REST verbs, `inventory_sync` for scheduled `DeviceDiscovery` emission. Resolves credential broker grants per-request to obtain base_url + token; never holds plaintext credentials at rest. |

**Why this is the right shape:**
- Honest about the network: every AWX call goes where it has to (through the agent). No SaaS-plane → AWX exception.
- Uses two existing edge patterns instead of inventing a new one: per-call dispatch (proxmox credential test, mtr.run) and scheduled `DeviceDiscovery` emission (proxmox-inventory plugin). Both already battle-tested.
- No long-lived streams. Per-tick CommandBus dispatch has bounded latency and bounded resource use, scales with number of controllers (not number of runs), and resumes for free across agent reconnects (every tick reads `last_event_id` from the DB).
- Plugin stays small and stateless. One agent, one plugin instance, N controllers, M active runs — no per-run state on the agent.

**Alternatives considered:**
- *Have Elixir core call AWX directly.* Wrong on the network. AWX isn't reachable from the SaaS plane.
- *Per-run streaming assignments.* Considered. Long-lived connections are fragile (agent reconnect, controller hiccups, tight per-stream cleanup), scale linearly with active runs, and require streaming-mode test harnesses. The user flagged this concern explicitly. Pulse polling gets ~2s latency floor (vs. ~1s for streaming) at a fraction of the operational complexity.
- *One stream multiplexed per controller.* Solves the per-run scaling problem but keeps the long-lived-connection failure mode. Pulse polling avoids both.
- *Put the state machine and persistence inside the plugin.* Wrong on persistence (the plugin has no DB), wrong on UI (the plugin can't render LiveView), and burns WASM agent CPU on bookkeeping that Elixir does for free.

### Decision 3a: Ansible-managed status is *derived* via plugin-emitted DeviceDiscovery.

Operators do not click a checkbox to mark a device as Ansible-managed. The `awx` WASM plugin's `inventory_sync` scheduled entrypoint walks each configured AWX controller's inventories and hosts, builds a `sdk.NewDeviceDiscovery("awx")` aggregate, and attaches it to its result. The existing agent → gateway → DIRE pipeline carries those records the rest of the way — exactly like the proxmox-inventory plugin does today (`go/cmd/wasm-plugins/proxmox/main.go:343,433`). DIRE merges the AWX host record with whatever existing device record matches by hostname / IP / FQDN, the same way it merges proxmox + armis + sweep records today. When a device's `discovery_sources` set contains `"awx"`, `Device.ansible_managed = true` and `Device.ansible_inventory_ref` is populated from the host metadata DIRE captured.

**No new ingestion plumbing on Elixir.** We are *not* adding an Elixir `InventorySyncWorker` that pulls AWX hosts via verb commands and writes through DIRE itself. That would duplicate a pipeline we already have. The plugin pushes; DIRE consumes.

**Why:** Operators already curate inventory in AWX (often via the proxmox community ansible inventory plugin, which is exactly the user's setup). Asking them to re-curate inside ServiceRadar is duplication and drift. Derivation handles the "AWX host disappears" case naturally — DIRE notices the source is gone, and `ansible_managed` flips back to false on the next sync. Reusing the existing plugin → DIRE pipeline keeps the architecture consistent with proxmox/unifi/armis and eliminates a whole class of "but how does the data get in" questions.

**Implication:** the earlier `devices.ansible.mark` permission is removed from this change. The state is computed; there is nothing to mark.

**Alternatives considered:**
- *Manual marking only.* Rejected per user direction.
- *Elixir-side `InventorySyncWorker` pulling via verb commands.* Considered (and proposed in earlier revisions). Inferior — duplicates the existing plugin → DIRE pipeline that already handles proxmox / armis / unifi inventory ingestion, and forces ansible inventory through a different code path than every other discovery source.
- *Manual override on top of derivation.* Considered for the case where DIRE matches incorrectly (e.g., two devices with the same hostname). Deferred — DIRE already supports merge-overrides as a general inventory primitive; if needed, ansible benefits from that work without a special override path here.

### Decision 3b: Multi-device fan-out via a generic Device Actions modal.

Launching a playbook against many devices uses AWX's native `limit:` parameter — one AWX job, N hosts. Operators select N devices in the inventory list, click `Run Task`, the **Device Actions** modal opens, they choose `Run Playbook`, fill any required `vars_prompt` / `survey_spec` inputs, and confirm. ServiceRadar creates **one** `PlaybookRun` with **N** `PlaybookRunTarget` rows; per-device status is tracked through the targets, and AWX events are attributed back to targets via host name.

The modal is structured as an extensible action registry (each action is a behaviour module: title, icon, requires-permission, target-selection-rule, render-form, on-confirm). v1 ships with a single registered action — `Run Playbook`. Future changes register additional actions (Run MTR, Perform Network Scan, etc.) without touching the modal infrastructure. The user explicitly called these out as future scope.

**Why:** The user's actual use case is "run this playbook on these 15 devices." Single-device-at-a-time would force fifteen identical clicks. AWX's `limit:` parameter is purpose-built for this; we'd be inventing problems by launching N separate AWX jobs.

**Schema implication:** `PlaybookRun` has many `PlaybookRunTarget` rows (1:N). The earlier `PlaybookHostStat` resource is folded into `PlaybookRunTarget` — same data, but now the per-device record is the primary target entity, not a stats sidecar.

### Decision 3c: Telemetry projects to OCSF events, no extra OTEL hop.

`EventIngestor` does dual writes per task result:

1. The structured Ash row (`PlaybookTaskResult` referencing a `PlaybookRunTarget`) — drives the run-detail UI, queryable via SRQL, source of truth for hierarchy.
2. An OCSF-shaped event into the existing observability events stream — drives the universal log viewer for free, queryable alongside other system signals.

We do **not** route this through the OTEL collector. Pushing into OTEL just to have it land back in our own observability tables adds a hop, an external dependency, and a serialization round-trip that buys us nothing because we're the producer *and* the consumer. OCSF is already the schema the events table speaks; emitting the right shape directly is the path of least resistance.

OCSF class selection (implementation detail, not locked here): each task result maps cleanly to either OCSF "Application Activity" (6003) or "Process Activity" (1007) depending on how granular the operator wants their log search. We'll pick during implementation; the requirement is "OCSF-shaped, in the existing events stream", not the specific class id.

**Why:** Direct write keeps the data path honest — same producer for both projections, no risk of one diverging from the other. The user's framing "we don't have to re-invent the wheel here" is exactly right; the wheel is the existing observability events table, not a new sink.

### Decision 3d: AshPaperTrail for audit on controller / repository / run lifecycle.

`AnsibleController`, `PlaybookRepository`, and `PlaybookRun` are tracked by AshPaperTrail. This gives us:

- Who launched a run, with what extra_vars, against which target list (and the exact catalog Playbook + AWX template at launch time, not "current state").
- Who canceled a run.
- Who registered / rotated / removed a controller.
- The full state-machine transition history of a run, with timestamps and triggering actor (system vs. operator).

This is non-negotiable for any system that pokes at customer infrastructure. PaperTrail is the standard Ash extension for this; no custom audit infrastructure.

**Why:** If a playbook has a bad day, somebody is going to want a paper trail. PaperTrail is a one-line addition per resource and writes to a `_versions` table that's queryable via SRQL like any other resource. Comes "for free" relative to writing custom audit hooks.

### Decision 3e: Retention is configurable via Helm / docker-compose with sensible defaults.

Two configurable knobs, both in `helm/serviceradar/values.yaml` and `docker-compose.yml`:

- `ansible.retention.run_detail_days` — how long the full task hierarchy (`PlaybookPlay`, `PlaybookTask`, `PlaybookTaskResult` rows + content blobs) is retained. **Default: 90.**
- `ansible.retention.run_summary_days` — how long `PlaybookRun` + `PlaybookRunTarget` rows are retained. **Default: null (forever).**

`RetentionWorker` (AshOban) sweeps daily: deletes detail rows past `run_detail_days`, optionally deletes run/target rows past `run_summary_days`. OCSF events follow the existing events-table retention policy; AshPaperTrail versions follow PaperTrail's own retention.

**Why:** "Forever" is a footgun in customers with lots of automation; aggressive defaults are also a footgun in customers who need history for compliance. Operator-tunable with reasonable defaults is the only honest answer.

### Decision 3f: Scheduled / recurring runs ship in v1, backed by AshOban.

Operators can register a `PlaybookSchedule` that pairs a launchable `Playbook`, a list of target devices, optional `extra_vars`, and a cron expression. An AshOban worker evaluates schedules at their cadence and creates a `PlaybookRun` exactly as if a human had clicked through the Device Actions modal. Schedules are first-class Ash resources with their own RBAC, audit (AshPaperTrail), enable/disable toggle, and SRQL alias.

Why pull this in for v1 (rather than deferring): AshOban already handles cron-driven jobs with retry, dedup, and isolation primitives we need anyway for `RunPulseWorker` and `RetentionWorker`. Adding `PlaybookSchedule` is an Ash resource + a worker + a screen — small marginal cost on top of the v1 plumbing, and the user's actual use case (cron runs against device fleets) needs it from day one. Delaying would mean operators stand up some external cron + API caller, which is the kind of glue we should not push onto them.

What the schedule resource holds:
- `name`, `enabled`, `owner_id`
- `playbook_id`, `target_device_uids[]` (must all share one controller; same launch-authorization rules as ad-hoc runs)
- `extra_vars` (jsonb)
- `cron` (standard 5-field cron, validated at write time)
- `timezone`
- `last_evaluated_at`, `last_run_id`, `next_run_at`

Concurrency: a schedule that fires while its previous `PlaybookRun` is still non-terminal SHALL skip the new firing and record a `skipped_overlap` reason on the schedule, rather than launching a second concurrent run. Operators can opt out per-schedule (`allow_concurrent: true`) but the default is "skip overlap".

**RBAC:** `ansible.schedules.view`, `ansible.schedules.manage`. Manage subsumes create / update / enable / disable / delete.

**UI:** a `Schedules` tab on `/ansible` plus a "Schedule this playbook" affordance from the Device Actions modal — same form as ad-hoc launch, plus a cron picker.

**Out of scope (still):** advanced calendar features (timezones-per-target, blackout windows, holiday calendars). Cron is enough for v1.



States: `pending → launching → running → (succeeded | partial | failed | unreachable | canceled)`. Transitions are guarded actions; the ingestor cannot move a `succeeded` run back to `running`. Each transition emits a telemetry span and a NATS event.

`partial` exists because multi-device runs may legitimately have a mixed outcome — some `PlaybookRunTarget`s succeed, others fail. AWX itself reports the job as `failed` if any host failed; we surface this more clearly as `partial` when it's mixed (and `failed` when *every* target failed). The distinction matters for the UI status pill, alert routing, and SRQL queries.

**Why:** Run state is high-stakes (operators make decisions from it) and there are real concurrency hazards — AWX status, ingestor polling, and user cancel can all race. State Machine gives us auditable, testable, deadlock-free transitions for free.

### Decision 5: AWX API token lives in the credential broker, not on the resource.

The `AnsibleController` Ash resource stores the AWX `base_url`, version, and a reference to a **credential broker** entry that holds the API token. This matches the existing pattern for plugin secrets (proxmox API tokens, UniFi tokens, AlienVault keys all flow this way today): operators register the controller, the API token is written into the broker, and the resource holds only the broker reference. When Elixir issues an AWX command, it requests a short-lived broker grant and embeds the grant in the `CommandRequest`. The plugin resolves the grant at the edge, decrypts the token, makes the call, and the grant expires.

SSH keys, become passwords, vault passwords are *never* sent to or stored by ServiceRadar — operators configure them in AWX once. The launch command payload contains only the AWX job_template_id, the host limit, and `extra_vars` (which may be empty).

**Alternatives considered:**
- *Store the token directly on `AnsibleController` via AshCloak.* Workable but inconsistent with existing plugin-secret patterns and gives Elixir an in-process plaintext token at decryption time. The broker keeps secrets at the edge of decryption.

### Decision 6: Event ingestion is pulse-based polling driven by an Elixir tick worker.

Each `AnsibleController` has its own `RunPulseWorker` (AshOban) that ticks every N seconds (default 2s, operator-configurable per controller). On each tick:

1. Read non-terminal `PlaybookRun` rows for this controller; if zero, skip.
2. Build a list of `(awx_job_id, last_event_id)` pairs from the rows.
3. Dispatch one `awx.fetch_events_for_jobs(pairs)` command via `AgentCommandBus` to the controller's agent.
4. The plugin makes one HTTP call per active job to `/api/v2/jobs/{id}/job_events/?since_id=N&page_size=200`, batches results, returns one `CommandResult` covering all jobs.
5. Elixir persists new events into `PlaybookPlay` / `PlaybookTask` / `PlaybookTaskResult` rows, advances each run's `last_event_id`, runs state-machine transitions, projects OCSF events.
6. Also dispatch `awx.fetch_job` for any run whose `last_event_id` hasn't moved in the past tick — this catches terminal-status transitions even when no new task events fire.

No long-lived connections. Every tick is a discrete request/response. Reconnect is invisible: if the agent is offline, the tick fails, the worker retries with backoff, and when the agent reconnects the *next* tick reads `last_event_id` straight from the DB and resumes — no special resume logic needed.

**Latency floor:** ~2s. For latency-sensitive customers the tick can be tuned down (500ms is fine for a single-digit-controller deployment); for very large deployments it can be tuned up (10s for cost-sensitive batch runs). Tick interval is per-controller via `AnsibleController.run_pulse_interval_ms` and overrides the default from Helm/docker-compose.

**Why poll-via-CommandBus instead of streaming or webhooks:**
- *Streaming* gets you ~1s latency but at the cost of N long-lived connections (one per active run, or one per controller multiplexed) with all the failure modes that implies. The user flagged this concern explicitly.
- *Webhooks* require AWX → ServiceRadar reachability, which is the opposite of our network direction. Deferred to v2 with the agent-side receiver sketch in the next section.
- Pulse-via-CommandBus uses the *exact* same primitive (`AgentCommandBus.dispatch`) that already drives every other AWX call. One mechanism, one set of failure modes, one set of telemetry hooks. Easy to test (mock the bus), easy to reason about (no concurrent connections), easy to scale (one tick worker per controller, not per run).

### Decision 7: Runs are queryable via SRQL.

We add SRQL resource aliases for `ansible_runs`, `ansible_playbooks`, `ansible_controllers` so an operator can write `SHOW ansible_runs WHERE device.id = "..." AND status = "failed" SINCE 24h`. This is the same pattern used by other domain entities and gives the data dashboard/alert reach without bespoke endpoints.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| AWX API rate limits under heavy poll load. | One `RunPulseWorker` per controller, not per run; tick interval configurable; watermark cursor avoids re-fetching; plugin applies exponential backoff on 429 within a tick; ticks with zero active runs are no-ops. |
| Git catalog parser misreads playbook metadata (yaml is permissive). | Parse via the same library as `ansible-lint`; on parse error, store raw playbook with `parse_status: error` and a diagnostic so it's still visible in the catalog as "broken" rather than missing. |
| AWX outage causes runs to appear stuck in `launching`/`running`. | Watchdog: any run in non-terminal state for >2× its job_template `timeout` (or 1h fallback) transitions to `unreachable` with a diagnostic. |
| Operator binds catalog playbook to wrong AWX job template. | UI shows AWX template name + project + branch on the run-launch confirmation; operator reviews before clicking "Run". |
| Credential broker token rotation. | Existing broker rotation paths apply; controller resource holds only a stable reference. Same as proxmox/unifi today. |
| Agent or plugin restart mid-run. | No special handling needed. The next `RunPulseWorker` tick after the agent reconnects reads `last_event_id` from the DB and resumes from the last event Elixir actually persisted. No lost connections to clean up. |
| AWX inventory drifts from ServiceRadar inventory. | `InventorySyncWorker` re-runs on a schedule; DIRE handles disappearance the same way it handles any other vanished discovery source. `ansible_managed` flips back to false on next sync if the AWX host is gone. |
| DIRE merges an AWX host with the wrong ServiceRadar device (hostname collision). | DIRE already supports merge-overrides as a generic primitive; ansible inherits that. UI shows the AWX host name + inventory on the device page so operators can spot mis-merges. |
| Multi-device run with one slow host blocks the entire run. | AWX has its own `forks` and per-host timeout; we don't change that. UI shows per-target progress so operators can see the slow host without ambiguity. |
| OCSF event class for ansible task results is wrong. | Class selection is implementation-time, not spec-locked. Easy to migrate by re-projecting from the structured tables. |
| Retention worker deletes detail rows that an operator was actively viewing. | Worker excludes runs touched (read or written) within the last hour; UI shows a banner when a run's detail has been pruned. |
| Run-launch flow leaks AWX-only error messages to UI. | All AWX errors normalized through `Serviceradar.Automation.Ansible.AwxClient` into typed errors with operator-safe summaries. |
| Long-running runs hold a poll worker. | Each run has its own AshOban job; concurrency capped per-controller; finished runs deschedule themselves. |

## Migration Plan

This is a purely additive change. No existing tables, schemas, or APIs change behavior. Rollout:

1. Ship Ash resources (codegen migration) + RBAC permissions in a deploy that's idle until a controller is configured.
2. Operators register their first AWX controller via `/settings/ansible`; health check goes live.
3. Operators register one or more git repositories; catalog populates.
4. Operators mark devices as Ansible-managed; UI shows the Run Playbook action.
5. First runs launch; ingestor populates the run hierarchy.

Rollback: feature is gated by absence of any `AnsibleController` rows. Drop those rows and the feature is effectively off; data is retained for forensics.

## Deferred to v2: Webhook Augmentation

For v1 we use polling-from-the-edge exclusively. AWX *Notifications* (job-level: started, succeeded, failed) could augment this in v2 if a customer brings a concrete need — e.g., a large AWX deployment where 1s polling cadence creates noticeable API load, or a desire for sub-second state-transition latency in the UI. We are not building this in v1, but we are reserving the design space so it doesn't paint us into a corner.

Sketch (not committed):

- **Receiver lives on the agent, not web-ng.** AWX may not have a network path to web-ng or to the SaaS plane, but by definition it has a path to the agent because the agent already reaches AWX. The webhook receiver therefore belongs on the agent, where ingress can be exposed inside the customer's network without crossing trust boundaries.
- **Agent exposes an HMAC-validated `POST /awx/webhook/:controller_id` endpoint** (likely as a new agent surface, not via the WASM plugin — plugins don't currently accept inbound HTTP). The shared HMAC secret rides in the credential broker entry alongside the API token.
- **Webhook events feed the same persistence path** that pulse polling feeds. The agent transforms the webhook payload into something equivalent to an `awx.fetch_events_for_jobs` response and writes through to Elixir via the existing CommandBus pipeline (or a new "ingest event" verb). Pulse polling stays as a backstop so misconfigured webhooks don't drop events silently.
- **Webhooks are an optimization, not a replacement.** AWX Notifications are job-level only — per-task / per-host events still come from `/api/v2/jobs/{id}/job_events/`. Polling stays. Webhooks reduce state-transition latency and shift some lifecycle load off polling.
- **Failure modes:** webhooks can drop silently if AWX Notification config drifts; polling backstops this naturally. The reconcile that already keeps `last_event_id` consistent gives us at-most-once-from-each-source plus at-least-once-overall.

This is enough of a sketch to commit to *not* doing it in v1 without losing the path. We'll revisit when a real customer brings a real problem.

## Open Questions

1. **`extra_vars` UX for git-sourced playbooks.** Default proposal: parse `vars_prompt` from the playbook and render a launch dialog with typed inputs; for unknown vars, allow a raw-YAML override behind a toggle. AWX-sourced playbooks use the AWX `survey_spec` natively — no question there.
2. **Catalog git auth.** Catalog repo sync runs in Elixir (the *catalog*, unlike the AWX network calls, is fetchable from the SaaS plane — git repos generally live on github/gitlab.com). Default proposal: HTTPS deploy token via the existing credential broker; SSH deferred. If a customer hosts a private git server inside their own network, the sync moves to a plugin verb — v2 concern.
3. **OCSF class selection for task results.** "Application Activity" (6003) vs. "Process Activity" (1007). Default proposal: pick during implementation by looking at how operator searches actually shape up. Easy to re-project from the structured tables if we get it wrong.
4. **DIRE matching keys for AWX hosts.** AWX hosts carry `name` (free-form) and a `variables` blob that *may* contain `ansible_host` (IP / hostname). Default proposal: try in order — exact `ansible_host` IP match, exact `ansible_host` hostname match, AWX `name` matched against device hostname. Surface unmatched AWX hosts in the `/settings/ansible` page so operators can resolve manually.
5. **Default `run_pulse_interval_ms`.** 2000 ms feels right for the typical case (a handful of controllers, < 100 active runs). Should we ship a per-controller default that's higher (5s) and recommend operators tune down? Default proposal: 2000 ms in defaults, document the trade-off, let operators adjust.
