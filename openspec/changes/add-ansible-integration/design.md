## Context

ServiceRadar already has a rich device inventory (Ash + OCSF schema), an event/metric pipeline (NATS JetStream → EventBatcher → observability tables), an Ash-first data layer with AshOban (jobs), AshCloak (encryption), and Ash State Machine available, and — critically for this proposal — a `core → agent-gateway → agent → WASM plugin` network path that's the *only* way to reach customer-private resources. AWX/AAP almost always lives in the customer's private network alongside their inventory; ServiceRadar core (SaaS) cannot dial it directly. The agent must.

The relevant primitives that already exist:

- **`AgentCommandBus.dispatch/4`** (`elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex:24`) sends typed `CommandRequest` protos to an agent over the bidirectional `ControlStream` and receives one `CommandResult` per command. Used today by patterns like `proxmox.credential_test`, `mtr.run`, `mapper.run_job`.
- **PluginManager streaming mode** (`go/pkg/agent/plugin_runtime.go:181`) supports long-lived plugin assignments that emit a stream of chunks via `StreamStatus` (e.g. `stream_camera`, proxmox console). The host bridges chunks to the gateway and on into Elixir.
- **Credential broker grants** (`elixir/serviceradar_core/lib/serviceradar/credentials/`) — encrypted, short-lived references that travel in command payloads. Plugins resolve them at the edge to obtain target URLs and tokens. This is the existing pattern for cross-network secret hand-off; it replaces my earlier "store the AWX token via AshCloak on the resource" idea.
- **Multi-tenancy** is handled at the deployment layer, not the resource layer: each tenant runs their own stack (Elixir, agent-gateway, agents) in their own k8s namespace, sharing only Postgres (separate schemas) and NATS JetStream (subject-isolated). Resources do *not* need `tenant_id` columns for AWX-related work.

ARA is being prototyped in the cluster to capture playbook telemetry, but it duplicates a UI, a schema, and a Python service — none of which fit the ServiceRadar architecture, and none of which integrate with our RBAC, SRQL, or observability stack.

The user's primary use case is *"go into a device and run a playbook on it"* with durable evidence about exactly what was authorized and targeted. The execution backend is **AWX/AAP** (REST API, k8s/Docker/VM-deployable, already vault-aware, lives in the customer network). Git and AWX both feed catalog discovery, but hardened execution uses only an AWX-sourced playbook with a current approved immutable binding. Scope is on-demand execution for one or more exact targets in a single controller/inventory partition.

## Goals / Non-Goals

### Goals
- ServiceRadar derives Ansible-managed status from AWX discovery and links canonical devices to durable AWX memberships.
- Operators can register git repos as the canonical playbook catalog; metadata is parsed and indexed.
- Operators can launch a reviewed AWX-sourced playbook against one or more exact devices through the hardened launch service.
- Hardened launches persist canonical operation, child-execution, and exact-target evidence before dispatch.
- Operators inspect that evidence through `/ansible/operations` and `/ansible/operations/:id`; the retained internal run hierarchy is not created by hardened interactive launches or exposed as a second history UI.
- All authorization flows through the existing RBAC catalog; no bespoke permission system.
- Canonical operation and execution lifecycle evidence is immutable or constrained to explicit state transitions.

### Non-Goals (v1)
- Pushing devices into AWX inventory from ServiceRadar (we only *link* to existing AWX hosts).
- Storing SSH keys, become passwords, or vault passwords (AWX owns these).
- Direct `ansible-playbook` execution by a ServiceRadar agent (AWX-only in v1).
- Scheduled / recurring execution or schedule controls. Retained schedule rows remain disabled until a separate immutable-delegation design is approved.
- Raw JSON/YAML, undeclared variables, sensitive survey fields, or git `vars_prompt` as launch inputs.
- A new general-purpose "automation" framework — this proposal is Ansible-specific. If a second backend (e.g., direct exec) lands later, we'll generalize then.

## Decisions

### Decision 1: AWX is the execution backend; we never shell out to `ansible-playbook` in v1.

**Why:** AWX already solves credential vaulting, SSH-key isolation, executor scheduling, and inventory sync. Operators who run Ansible at any scale already have AWX or are migrating toward it. Building a parallel execution path in ServiceRadar duplicates a hard, security-sensitive system.

**Alternatives considered:**
- *Direct exec from a ServiceRadar agent + custom callback plugin (ARA's model).* Rejected for v1: it forces ServiceRadar into the credential-storage business and re-implements AWX's executor/inventory/vault. Could be a v2 plugin if there's demand from operators without AWX.
- *Use `ansible-runner` library directly.* Same drawbacks as direct exec, plus a Python runtime in our agent. Rejected.

### Decision 2: Catalog has git and AWX source types; hardened launch uses reviewed AWX entries.

The `Playbook` resource is polymorphic. It carries a `source_type` discriminator with two values in v1:

- `git` — ServiceRadar clones a registered `PlaybookRepository`, parses YAML, and derives metadata (name, description, declared `vars_prompt`, top-level vars, tags, hosts pattern) for discovery and review.
- `awx` — ServiceRadar pulls AWX Job Templates via `awx.list_templates` and treats each Job Template as a catalog entry. Survey data is retained as mutable catalog metadata, not used directly as the secure browser input contract.

Both sources can coexist and the same playbook may appear twice, with a source badge identifying its origin. This is catalog visibility, not launch authority.

For execution, only a parse-valid AWX-sourced row is eligible for the hardened launch picker. Selection and submit must resolve a current approved immutable template binding, exact durable memberships, current human authority, and live AWX preflight. A template ID on a git-sourced row does not make it launchable. Browser inputs come only from the approved binding's typed non-secret schema; mutable `survey_spec`, git `vars_prompt`, raw JSON/YAML, and secret fields cannot enlarge it.

**Why:** Operators benefit from discovering both repository and AWX metadata, but a catalog record is not an authorization boundary. Restricting execution to a reviewed AWX template binding keeps target, credential, revision, execution-environment, and input authority explicit.

**Alternatives considered:**
- *Git-only catalog.* Forces operators with mature AWX setups to re-register everything as a git repo. Rejected.
- *AWX-only catalog.* Hides useful source-repository discovery metadata. Rejected.
- *Treat a git row plus template ID as executable.* Rejected because it bypasses the reviewed AWX binding and immutable live-preflight contract.
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

### Decision 3b: Hardened launch surfaces persist canonical operation evidence.

Launching a playbook against many devices uses AWX's native `limit:` parameter — one AWX job, N exact hosts. Inventory selection navigates to `/ansible/launch`; device detail uses an in-panel launch modal for the current device. Both surfaces call the same `SecureLaunchService`, accept only approved typed non-secret binding inputs, and re-resolve the current human, binding, live AWX preflight, and durable memberships on submit. ServiceRadar first persists **one** canonical `AutomationOperation`, an inventory-bound `AutomationExecution`, and **N** immutable `AutomationExecutionTarget` rows. The reviewed plan then dispatches one AWX job for those exact targets. Interactive launch does not create a `PlaybookRun`.

The browser never supplies AWX membership IDs, inventory, host limit, credentials, callback policy, raw `extra_vars`, or secret inputs. Launch success navigates to `/ansible/operations/:id`; operation and device history read only canonical operation evidence.

**Why:** The user's actual use case is "run this playbook on these 15 devices." Single-device-at-a-time would force fifteen identical clicks. AWX's `limit:` parameter is purpose-built for this; we'd be inventing problems by launching N separate AWX jobs.

**Schema implication:** canonical launch evidence has one operation with inventory-bound child executions and exact target rows. The retained `PlaybookRun` / `PlaybookRunTarget` hierarchy remains an internal ingestion and audit concern until a separately approved backend migration replaces or retires it; it does not drive the operator history UI.

### Decision 3c: Telemetry projects to OCSF events, no extra OTEL hop.

`EventIngestor` does dual writes per task result:

1. The structured Ash row (`PlaybookTaskResult` referencing a `PlaybookRunTarget`) — retained for ingestion, audit, retention, and SRQL; it does not drive a separate run-detail UI.
2. An OCSF-shaped event into the existing observability events stream — drives the universal log viewer for free, queryable alongside other system signals.

We do **not** route this through the OTEL collector. Pushing into OTEL just to have it land back in our own observability tables adds a hop, an external dependency, and a serialization round-trip that buys us nothing because we're the producer *and* the consumer. OCSF is already the schema the events table speaks; emitting the right shape directly is the path of least resistance.

OCSF class selection (implementation detail, not locked here): each task result maps cleanly to either OCSF "Application Activity" (6003) or "Process Activity" (1007) depending on how granular the operator wants their log search. We'll pick during implementation; the requirement is "OCSF-shaped, in the existing events stream", not the specific class id.

**Why:** Direct write keeps the data path honest — same producer for both projections, no risk of one diverging from the other. The user's framing "we don't have to re-invent the wheel here" is exactly right; the wheel is the existing observability events table, not a new sink.

### Decision 3d: AshPaperTrail for retained controller / repository / run lifecycle.

`AnsibleController`, `PlaybookRepository`, and `PlaybookRun` are tracked by AshPaperTrail. This gives us:

- Historical internal run attribution and state changes, without accepting or retaining raw requested variables on current create/update actions.
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

### Decision 3f: Scheduled execution remains fail-closed pending immutable delegation.

`PlaybookSchedule`, its PaperTrail history, and `ScheduleEvaluatorWorker` remain internal compatibility surfaces until a separate approved migration either replaces or retires them. Schedule rows default disabled, the enable action rejects, raw requested variables are not accepted by create/update actions, and the evaluator's call into the retired launcher fails closed. No schedule tab, schedule form, enable/disable control, schedule detail route, or "Schedule this playbook" affordance is part of the supported UI.

Future scheduled execution must define an expiring/revocable `AutomationExecutionDelegation`, reauthorize its immutable ceilings at fire time, accept only approved typed non-secret inputs, and persist resulting evidence as an `AutomationOperation`. System workers may transport an approved plan but cannot become the authorizing principal. That capability is outside this change.



States: `pending → launching → running → (succeeded | partial | failed | unreachable | canceled)`. Transitions are guarded actions; the ingestor cannot move a `succeeded` run back to `running`. Each transition emits a telemetry span and a NATS event.

`partial` exists because multi-device runs may legitimately have a mixed outcome — some `PlaybookRunTarget`s succeed, others fail. AWX itself reports the job as `failed` if any host failed; we surface this more clearly as `partial` when it's mixed (and `failed` when *every* target failed). The distinction matters for the UI status pill, alert routing, and SRQL queries.

**Why:** Run state is high-stakes (operators make decisions from it) and there are real concurrency hazards — AWX status, ingestor polling, and user cancel can all race. State Machine gives us auditable, testable, deadlock-free transitions for free.

### Decision 5: AWX API token lives in the credential broker, not on the resource.

The `AnsibleController` Ash resource stores the AWX `base_url`, version, and a reference to a **credential broker** entry that holds the API token. This matches the existing pattern for plugin secrets (proxmox API tokens, UniFi tokens, AlienVault keys all flow this way today): operators register the controller, the API token is written into the broker, and the resource holds only the broker reference. When Elixir issues an AWX command, it requests a short-lived broker grant and embeds the grant in the `CommandRequest`. The plugin resolves the grant at the edge, decrypts the token, makes the call, and the grant expires.

SSH keys, become passwords, and vault passwords are *never* sent to or stored by ServiceRadar — operators configure them in AWX once. The launch body is produced server-side from the immutable binding and exact target snapshot. It carries only reviewed typed non-secret inputs plus reserved dispatch markers; the browser cannot provide arbitrary `extra_vars`.

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
| An AWX template or project drifts from its approved binding. | Selection and submit resolve the current approved binding and live AWX preflight; drift keeps launch unavailable until an authorized reviewer creates a new binding version. |
| Credential broker token rotation. | Existing broker rotation paths apply; controller resource holds only a stable reference. Same as proxmox/unifi today. |
| Agent or plugin restart mid-run. | No special handling needed. The next `RunPulseWorker` tick after the agent reconnects reads `last_event_id` from the DB and resumes from the last event Elixir actually persisted. No lost connections to clean up. |
| AWX inventory drifts from ServiceRadar inventory. | `InventorySyncWorker` re-runs on a schedule; DIRE handles disappearance the same way it handles any other vanished discovery source. `ansible_managed` flips back to false on next sync if the AWX host is gone. |
| DIRE merges an AWX host with the wrong ServiceRadar device (hostname collision). | DIRE already supports merge-overrides as a generic primitive; ansible inherits that. UI shows the AWX host name + inventory on the device page so operators can spot mis-merges. |
| Multi-device run with one slow host blocks the entire run. | AWX has its own `forks` and per-host timeout; we don't change that. UI shows per-target progress so operators can see the slow host without ambiguity. |
| OCSF event class for ansible task results is wrong. | Class selection is implementation-time, not spec-locked. Easy to migrate by re-projecting from the structured tables. |
| Retention removes internal task detail. | Canonical immutable operation evidence is stored separately and is not removed or altered by internal run-detail pruning. |
| Run-launch flow leaks AWX-only error messages to UI. | All AWX errors normalized through `Serviceradar.Automation.Ansible.AwxClient` into typed errors with operator-safe summaries. |
| Long-running runs hold a poll worker. | Each run has its own AshOban job; concurrency capped per-controller; finished runs deschedule themselves. |

## Migration Plan

This is a purely additive change. No existing tables, schemas, or APIs change behavior. Rollout:

1. Ship Ash resources (codegen migration) + RBAC permissions in a deploy that's idle until a controller is configured.
2. Operators register their first AWX controller via `/settings/ansible`; health check goes live.
3. Operators register one or more git repositories; catalog populates.
4. AWX inventory discovery creates durable memberships and derives Ansible-managed device status.
5. An authorized reviewer approves an AWX template binding; hardened launches create canonical operation/execution/target evidence before dispatch.

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

1. **Future git-sourced execution.** Git rows remain catalog-only. Any future executable mapping must produce the same reviewed immutable AWX binding and typed non-secret input contract; it cannot add a raw-variable escape hatch.
2. **Catalog git auth.** Catalog repo sync runs in Elixir (the *catalog*, unlike the AWX network calls, is fetchable from the SaaS plane — git repos generally live on github/gitlab.com). Default proposal: HTTPS deploy token via the existing credential broker; SSH deferred. If a customer hosts a private git server inside their own network, the sync moves to a plugin verb — v2 concern.
3. **OCSF class selection for task results.** "Application Activity" (6003) vs. "Process Activity" (1007). Default proposal: pick during implementation by looking at how operator searches actually shape up. Easy to re-project from the structured tables if we get it wrong.
4. **DIRE matching keys for AWX hosts.** AWX hosts carry `name` (free-form) and a `variables` blob that *may* contain `ansible_host` (IP / hostname). Default proposal: try in order — exact `ansible_host` IP match, exact `ansible_host` hostname match, AWX `name` matched against device hostname. Surface unmatched AWX hosts in the `/settings/ansible` page so operators can resolve manually.
5. **Default `run_pulse_interval_ms`.** 2000 ms feels right for the typical case (a handful of controllers, < 100 active runs). Should we ship a per-controller default that's higher (5s) and recommend operators tune down? Default proposal: 2000 ms in defaults, document the trade-off, let operators adjust.
