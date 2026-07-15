## ADDED Requirements

### Requirement: AWX execution identity uses immutable inventory memberships
ServiceRadar SHALL identify an AWX inventory membership by `(controller_id, inventory_id, awx_host_id)` and link it explicitly to one canonical device UID for execution. It SHALL preserve multiple memberships and duplicate display hostnames, retain source generation/currentness/linkage evidence, and MUST NOT select or merge an execution target by hostname, IP address, facts, labels, or last-writer-wins device metadata.

#### Scenario: Farm01 and tonka01 share a hostname
- **WHEN** both inventories contain `pve01` with different inventory/host IDs and addresses
- **THEN** ServiceRadar preserves two distinct memberships and requires the operator/policy to select the exact compatible membership

#### Scenario: Device has multiple AWX memberships
- **WHEN** one canonical device legitimately appears in two inventories
- **THEN** both memberships remain visible and only the membership compatible with the bound template is used for a child launch

#### Scenario: Membership drifts
- **WHEN** host ID, inventory, enabled state, address, generation, or canonical-device link differs from the approved launch snapshot
- **THEN** ServiceRadar rejects the target without hostname/IP fallback

### Requirement: Launch planning is exact, partitioned, and transactional
ServiceRadar SHALL create one immutable parent operation and partition it into child executions by controller, inventory, job template, immutable project/SCM commit/content hash, execution environment, approved machine credential reference, reviewed static custom credential or dynamic custom-credential type/slot, and check/run mode. It SHALL re-fetch current template/host state, reject moving refs and project `update_on_launch`, require an explicit compatible inventory and literal-only non-empty limit, persist all child targets in one transaction before dispatch, and prove equality among requested, planned, persisted, and command target tuples/counts. AWX acceptance SHALL echo the exact inventory and literal limit; post-start job-host summaries SHALL reconcile to the snapshotted host IDs before ServiceRadar marks scope verified. The system MUST NOT claim synchronous AWX acceptance returns an expanded host-ID set.

#### Scenario: Selection spans two inventories
- **WHEN** an authorized request selects targets in farm01 and tonka01
- **THEN** ServiceRadar creates separate inventory-bound child executions under one parent and retains every source tuple

#### Scenario: Empty limit would use template defaults
- **WHEN** any target lacks a validated unique AWX inventory host name or the derived child limit is empty
- **THEN** ServiceRadar rejects the child and MUST NOT omit the limit or launch the template's full inventory

#### Scenario: Host name contains limit syntax
- **WHEN** an inventory host name contains commas, pattern operators, colons, brackets, `@`, backslashes, whitespace/control characters, or does not match `[A-Za-z0-9][A-Za-z0-9._-]{0,254}`
- **THEN** ServiceRadar rejects exact launch until AWX provides a safe unique literal alias

#### Scenario: Template inventory is incompatible
- **WHEN** the selected inventory differs from a template's fixed inventory or a required inventory/limit/check prompt is not allowed
- **THEN** ServiceRadar rejects the launch rather than relying on template defaults

#### Scenario: Target row cannot be persisted
- **WHEN** any requested child target fails validation, uniqueness, or persistence
- **THEN** the whole plan aborts before AWX dispatch and reports the exact failed target

#### Scenario: Accepted job host scope differs
- **WHEN** AWX does not echo the exact inventory/literal limit or job-host reconciliation has missing, extra, duplicate, or different host IDs
- **THEN** the child fails closed, cancels the job where possible, emits security diagnostics, and holds affected canonical devices for a mutating operation

### Requirement: Initiating authority survives asynchronous execution
Every launch SHALL record and authorize the initiating human or explicitly owned fixed-ceiling service principal, tenant, permission/role version, target policy, action, approval, and request source before planning and at dispatch. A schedule SHALL store an expiring/revocable `AutomationExecutionDelegation` containing issuer principal ID, execution principal type/ID, owner, tenant, issue/expiry/revocation, and immutable ceilings for permissions, action/template/revision, non-secret inputs, exact target memberships, approval, and run budget; it SHALL NOT store/reconstruct a user bearer. Issuance SHALL require schedule-management and the issuer's launch/target authority. Selecting a separate service principal SHALL additionally require exact `ansible.delegations.manage`, administrator-only by default, verified ownership, and a fixed principal ceiling. The issuance ceiling SHALL be the intersection of issuer-delegable scope, execution-principal fixed/current authority, approval, and deployment maximum. Fire-time authority SHALL further intersect current issuer/principal/owner state, binding/targets/policy, and approval. Disable, expiry, revocation, ownership change, or contraction SHALL stop execution pending reapproval. System workers MAY transport an approved immutable plan but MUST NOT become the authorizing principal or enlarge authority. Later permission expansion SHALL NOT enlarge an existing plan; contraction SHALL deny/cancel incomplete work.

#### Scenario: Worker dispatches a human request
- **WHEN** an Oban/SystemActor worker sends a previously approved AWX command
- **THEN** audit retains the human initiator separately from the worker and the worker can transport only the immutable plan

#### Scenario: Schedule owner loses authority
- **WHEN** a schedule's owner/service principal is disabled or loses launch/target permission before fire
- **THEN** no child is dispatched and SystemActor authority does not substitute

#### Scenario: Permission expands after planning
- **WHEN** the initiator gains access to more targets or actions after the snapshot
- **THEN** the existing operation retains its issuance-time ceiling

#### Scenario: Schedule delegation expires
- **WHEN** a schedule delegation expires, is revoked, loses its owner, or no longer intersects current authority
- **THEN** the schedule does not fire and no worker/user token substitutes for it

#### Scenario: Creator selects a stronger service principal
- **WHEN** a schedule creator lacks `ansible.delegations.manage`, ownership, or delegable scope for the selected service principal
- **THEN** ServiceRadar rejects issuance and cannot use that principal to exceed the creator's permitted ceiling

#### Scenario: Authority contracts during a job
- **WHEN** RBAC, membership, delegation, approval, target policy, or binding authority contracts while a child is active
- **THEN** change invalidation or bounded pulse/watchdog reauthorization revokes callbacks, cancels active children, stops later waves, and records `cancel_failed` plus mutation holds when stop/rollback is unproven

### Requirement: Launch inputs and credential custody are secret safe
Catalog bindings SHALL pin template, project, immutable SCM commit/content hash, execution environment, allowed inventories, approved machine credential references, reviewed static custom credentials or dynamic custom-credential type/slots, non-secret input schema, callback action declarations, and check-mode behavior. Moving branch/tag refs and project `update_on_launch` are forbidden. The accepted job SHALL match template, inventory, literal limit, project, exact `scm_revision`, execution environment, credential IDs/types, and check/run mode before binding. ServiceRadar SHALL accept only declared typed non-secret inputs; input schemas MUST reject `ansible_*` transport/connection variables and inventory/play magic variables that could retarget or change execution scope through extra-variable precedence. AWX surveys SHALL be restricted to reviewed non-secret prompts. This child SHALL NOT collect/resolve secret launch values. It MAY persist canonical public/internal values, classifications, credential references, and plan digests, but MUST NOT persist/transport plaintext secret-capable raw YAML, arbitrary `extra_vars`, callback bearers, API tokens, passwords, private keys, become/vault secrets, or secret-value digests in run/schedule rows, Oban args, commands, audit, PaperTrail, events, logs, support data, backup, or UI.

#### Scenario: User submits undeclared raw variables
- **WHEN** a launch supplies raw YAML, an undeclared field, or a sensitive value outside its reviewed credential mechanism
- **THEN** ServiceRadar rejects the request before run creation or AWX contact

#### Scenario: Reviewed input attempts to override Ansible execution scope
- **WHEN** a binding or survey declares `ansible_host`, `ansible_connection`, another `ansible_*` variable, or an inventory/play magic variable as operator input
- **THEN** the binding is non-launchable and the value never reaches AWX `extra_vars`

#### Scenario: Reviewed sensitive input is required
- **WHEN** a bound template requires a password, key, vault/become value, or other secret
- **THEN** the binding must use an approved prebound AWX machine/custom credential ID or a separately approved ephemeral callback credential and ServiceRadar does not collect the value

#### Scenario: Operator inspects run history
- **WHEN** run, job, event, audit, schedule, failure, or support records are viewed
- **THEN** they expose input names/classifications/references/digests as authorized but no reusable secret value

#### Scenario: Legacy raw variables are migrated
- **WHEN** existing run/schedule/PaperTrail action data may contain raw secret-capable variables
- **THEN** active data is purged/redacted without low-entropy secret hashes, restores scrub it before traffic, immutable backups expire under bounded retention/tombstones, and operators rotate any credential that may have appeared

#### Scenario: Accepted job supply chain drifts
- **WHEN** AWX reports a different project commit, execution environment, credential ID/type, check/run mode, template, inventory, or literal limit
- **THEN** ServiceRadar refuses job binding, invokes cancellation/cleanup, and records the exact non-secret drift

### Requirement: AWX controller bearer use is endpoint attenuated
Every on-demand AWX controller bearer grant SHALL contain non-empty method, host, normalized effective port, and verb-specific exact or argument-derived path ACLs. ServiceRadar SHALL accept only an origin-only HTTP(S) controller URL, derive port 443 for HTTPS or 80 for HTTP when no explicit port is supplied, and bind the grant to that one host and port. Each supported plugin verb SHALL have an explicit reviewed endpoint mapping. A generic `/api/v2/` fallback is forbidden. Unknown verbs, malformed verb arguments, unsupported schemes, empty hosts, invalid ports, embedded URL credentials, and controller URL path/query/fragment input SHALL fail before grant issuance, secret resolution, HTTP execution, or command dispatch.

The agent host MAY augment operating-system trust roots with an operator-configured bounded list of absolute PEM CA bundle paths for credential-bearing plugin HTTP. It SHALL load and validate those bundles outside Wasm memory, SHALL NOT place their contents in plugin configuration or allow a module to select/replace them, and SHALL keep certificate and hostname verification enabled. A configured relative, missing, unreadable, empty, oversized, or certificate-free bundle SHALL disable outbound plugin HTTP rather than fall back to an unverified transport. A trust-bundle change SHALL require host reinitialization before use.

Every unsafe on-demand AWX request SHALL use a v2 bearer grant with a typed request-body policy and a non-empty grant ID. Launch policy SHALL bind a strict maximum size and SHA-256 to exact control-plane-serialized bytes transported outside Wasm; the trusted agent SHALL replace, not trust or canonicalize, the plugin body. Empty-body mutations SHALL explicitly carry `mode: empty`. Secret-bearing callback creation SHALL use only the reviewed `awx_callback_credential.v1` trusted host rewriter. Each unsafe grant SHALL authorize at most one mutation. Body-policy validation, exact-byte substitution or trusted rewrite, content-type/framing enforcement, and one-use reservation SHALL complete before controller-token resolution and transport. Legacy v1 SHALL remain valid only for safe empty-body reads and scheduled inventory sync; an unsafe AWX request under v1 SHALL fail closed.

Before opaque launch-body encoding, ServiceRadar SHALL validate the entire derived body as a `CredentialRedactor` fixpoint. Launch `extra_vars` SHALL contain only reviewed names with bounded non-secret scalar values or scalar lists. Nested maps/lists, transport-retargeting names, private keys, PVE tokens, secret-bearing fields, and any redactor-changing content in `extra_vars`, limits, tags, or other launch fields SHALL be rejected before grant issuance. Missing or mismatched trusted bytes, an unreviewed body source/handler/content type, a non-empty body under an empty policy, a body on a safe AWX request, replay beyond the mutation limit, or any plugin attempt to change inventory, limit, credentials, or extra variables SHALL perform no resolver call and no network request. Trusted body buffers SHALL be cleared after use.

Scheduled `awx-inventory-sync` SHALL transport resolved sync bearers only in protobuf `PluginAssignmentConfig.host_params_json` field 23 and SHALL place only a fixed non-secret sentinel, never the bearer, broker payload, secret reference, or host envelope, in `params_json` exposed through Wasm `get_config`. The control-plane config-version projection SHALL replace raw host-envelope bearer values with deterministic SHA-256 fingerprints so rotation changes the version without placing raw credentials in the canonical version payload. An older agent receiving a new-control-plane assignment SHALL ignore unknown field 23 and fail closed with sentinel-only public params. A newer agent SHALL parse host material separately without merging it into `params_json`, SHALL reject any reserved host-envelope key inside public params, and MAY accept and scrub the legacy inline-token layout from an older control plane during the bounded rolling bridge. The trusted agent SHALL recognize only the exact inventory-sync plugin/entrypoint, retain one canonical HTTP(S) origin plus exact TLS verification policy per controller, and include a non-secret digest of public and host-only material in the assignment fingerprint. Malformed material, duplicate canonical origins or controller identities, ambiguous envelope/public rows, invalid bearer bytes, or origin/TLS mismatch SHALL leave no usable binding.

The dedicated host-envelope decoder SHALL reject unknown fields, trailing JSON, and empty controller identities so a future envelope extension cannot be interpreted as a weaker v1 contract by an older agent.

The scheduled host SHALL inject a retained bearer only when the plugin supplies the exact sentinel for an empty-body `GET` under `/api/v2/inventories/` on that exact origin with the configured `insecure_skip_verify` value. It SHALL reject other methods, bodies, origins, paths, plaintext/plugin-selected bearer values, encoded or double-encoded traversal, and TLS-policy mismatches before transport. Query values MUST NOT alter path/origin/credential selection. The credential-bearing edge HTTP boundary MUST NOT follow redirects.

#### Scenario: Exact template launch is dispatched
- **WHEN** ServiceRadar launches reviewed job template `42` through `https://awx.example.com`
- **THEN** its v2 bearer grant permits only `POST`, host `awx.example.com`, port `443`, exact path `/api/v2/job_templates/42/launch/`, and the exact control-plane-produced launch bytes for one mutation

#### Scenario: AWX uses an internal certificate authority
- **WHEN** the selected agent is configured with the internal CA bundle and AWX presents a hostname-valid certificate issued by that CA
- **THEN** the host verifies the TLS chain using its augmented trust pool while the Wasm module receives neither the CA bytes nor a trust-selection control

#### Scenario: Configured private CA cannot be loaded
- **WHEN** a configured plugin HTTP CA path is relative, missing, unreadable, oversized, empty, or contains no certificate
- **THEN** the agent disables outbound plugin HTTP and does not send the AWX bearer over an unverified connection

#### Scenario: Plug-in changes launch scope in its request body
- **WHEN** AWX Wasm changes the launch inventory, limit, credential IDs, or `extra_vars`, or supplies any other body than the authorized launch body
- **THEN** the trusted host sends only the exact bound control-plane bytes, or fails before bearer resolution and transport when those bytes are absent or invalid

#### Scenario: Mutating grant is replayed
- **WHEN** the plug-in attempts a second unsafe request using the same one-use v2 grant
- **THEN** the edge host rejects it before controller-token resolution and network transport

#### Scenario: Legacy on-demand grant attempts mutation
- **WHEN** an on-demand AWX v1 grant is used for POST, PUT, PATCH, or DELETE
- **THEN** the edge host rejects it while safe empty-body reads and scheduled inventory-sync remain compatible

#### Scenario: Callback creation needs secret body fields
- **WHEN** the callback lifecycle creates an ephemeral AWX credential
- **THEN** only the reviewed trusted host rewriter constructs the body from in-memory material, and no authorized raw body or secret input enters command data or Wasm config

#### Scenario: Controller scope cannot be derived
- **WHEN** a verb is unknown, an ID-bearing argument is malformed, or the controller URL has an invalid scheme, host, port, credentials, path, query, or fragment
- **THEN** ServiceRadar issues no bearer grant, resolves no controller token, performs no AWX HTTP request, and dispatches no command

#### Scenario: Credential-backed AWX endpoint redirects
- **WHEN** an allowed AWX endpoint returns any redirect, including one to the same host or a different port
- **THEN** the edge HTTP boundary rejects the response without replaying the bearer at the redirect destination

#### Scenario: Scheduled inventory config reaches Wasm
- **WHEN** the control plane delivers resolved credentials for one or more scheduled AWX controllers
- **THEN** Wasm sees normalized controller metadata and the fixed host-injection sentinel while the trusted agent alone retains the exact-origin bearer bindings

#### Scenario: New control plane reaches an older agent
- **WHEN** a control plane sends sentinel-only `params_json` and bearer material in protobuf field 23 to an agent that does not know field 23
- **THEN** the older agent ignores the unknown host field, receives no reusable credential, and the scheduled sync fails closed instead of exposing the bearer through `get_config`

#### Scenario: Host envelope is smuggled through public params
- **WHEN** an assignment places `_serviceradar_host_credentials` in `params_json`, even if its structure and controller rows otherwise appear valid
- **THEN** the newer agent rejects the assignment to empty Wasm config and retains no credential binding

#### Scenario: Host envelope carries unreviewed semantics
- **WHEN** protobuf field 23 contains an unknown envelope or controller field, trailing JSON, or an empty controller identity
- **THEN** the newer agent rejects the whole host credential set, exposes empty Wasm config, and retains no bearer binding

#### Scenario: New agent receives a legacy assignment
- **WHEN** an older control plane sends the bounded legacy inline-token inventory-sync layout to a newer agent
- **THEN** the newer agent extracts and scrubs the token before `get_config` and applies the same exact-origin, path, method, body, and TLS host checks

#### Scenario: Scheduled plugin changes credential scope
- **WHEN** scheduled AWX Wasm requests a different origin, a path outside `/api/v2/inventories/`, a non-GET method, a request body, a plaintext bearer, traversal encoding, or a TLS policy different from its host binding
- **THEN** the trusted agent denies the request before any network transport or bearer transmission

#### Scenario: Scheduled controller bearer rotates
- **WHEN** host-only controller bearer material changes while Wasm-visible params remain identical
- **THEN** the assignment fingerprint changes and the refreshed host binding is applied without exposing bearer material in the fingerprint or Wasm config

### Requirement: Check mode and callback actions cannot be variable-forged
Dry runs SHALL use native AWX check mode or a separately reviewed check template. A raw variable MUST NOT simulate check mode. For callback-enabled content, the immutable authority snapshot SHALL pin the exact reviewed action plus ephemeral custom-credential type/dynamic slot. The targeting child SHALL call callback-owned lifecycle interfaces: `prepare(snapshot, actor)` after the complete local plan exists; `materialize_attach(ref, child)` so the trusted dispatcher creates/binds the per-child instance and appends only its ID to dispatch state; `bind_activate(ref, controller, job, full_snapshot)` only after exact post-start job-host-summary equality marks the child `scope_verified`, with callback requests remaining pending before then; and `revoke_cleanup(ref, outcome)` to revoke/close grant state as appropriate and detach/delete the instance on create/launch/scope mismatch/ambiguity/partial-dispatch/cancel/consumption and every successful or failed terminal outcome. This child MUST NOT mint, resolve, activate, consume, or revoke a grant itself. Reusable static callback credentials and callback AWX external state before local plan commit are forbidden. Browsers, surveys, inventory, ordinary variables, and workers MUST NOT supply or override callback URLs, bearers, actions, credential instances, or response data.

#### Scenario: Template cannot run in check mode
- **WHEN** no native check support or approved check template is bound
- **THEN** ServiceRadar reports check mode unavailable and does not launch a mutating job

#### Scenario: Callback gate dependency is absent
- **WHEN** a binding declares `remote_access.ssh_ca.bundle.read` but callback-grant enforcement is not installed and approved
- **THEN** the binding remains non-launchable instead of receiving a worker/platform credential

#### Scenario: Ephemeral callback credential cannot launch
- **WHEN** preparation/credential creation fails or the AWX job never reaches exact verified acceptance
- **THEN** ServiceRadar invokes callback-owned detach/delete/revoke cleanup and cannot reuse a static credential or mutate the authority snapshot

### Requirement: AWX jobs and events are controller-child-target scoped
ServiceRadar SHALL bind an accepted job as `(controller_id, awx_job_id)` to exactly one local child execution and immutable snapshot. Polling, watchdog, cancellation, links, state transitions, and OCSF projection SHALL use that binding. Per-host results SHALL correlate by AWX host ID within the child target snapshot. Name-only events SHALL be enriched from job-scoped AWX host evidence to exactly one host ID or fail visibly; hostname/address fallback is forbidden.

Every AWX result SHALL be projected into a reviewed secret-free schema at the edge and control-plane ingress and SHALL satisfy a 3 MiB encoded aggregate budget. Only a gateway-tracked `awx.*` command MAY receive that enlarged budget; other and untracked commands remain under the generic cap. Event results SHALL carry contract version `2`, contain at most ten unique jobs and ten projected events per job, retain only reviewed structural fields and numeric `rc`, and use fixed failures. During the one-release v0.1.5 rolling bridge, ingress MAY accept only the exact legacy event envelope and MUST re-project it into bounded v2 windows, normalize null idle arrays and arbitrary errors, and discard all raw module/controller fields before persistence or fanout.

#### Scenario: Controllers reuse a job ID
- **WHEN** two AWX controllers each return job ID `42`
- **THEN** ServiceRadar attributes each job/event only within its controller and child execution

#### Scenario: Duplicate runner host string appears
- **WHEN** child jobs report the same display host name for different host IDs
- **THEN** each result resolves through its child/inventory host ID and both outcomes are preserved

#### Scenario: Event target is unknown or ambiguous
- **WHEN** an event cannot be enriched to exactly one snapshotted AWX host ID or names an extra target
- **THEN** ServiceRadar records an attribution failure and does not apply it to a guessed target

#### Scenario: AWX package is still on event contract v0.1.5 during rollout
- **WHEN** the prior package returns a null idle array, arbitrary failure text, or more than ten raw events for an otherwise exact bounded job batch
- **THEN** ingress discards the failure text and raw module fields, normalizes idle state, and advances through projected ten-event v2 windows without skipping a watermark

#### Scenario: Projected AWX result exceeds its aggregate budget
- **WHEN** individually valid catalog, survey, summary, or event fields encode above 3 MiB
- **THEN** the plug-in and ingress fail the command with fixed secret-free evidence rather than forwarding or partially persisting the oversized result

### Requirement: Dispatch ambiguity and cancellation fail closed
ServiceRadar SHALL bind a unique dispatch nonce and full child snapshot before contacting AWX and add reserved typed non-secret launch `extra_vars` `serviceradar_dispatch_id` and `serviceradar_snapshot_digest`; users and catalog inputs cannot set/override them. The reviewed AWX binding SHALL use exact contract `serviceradar.awx_dispatch_marker_survey/v1`: `survey_enabled=true`, `ask_variables_on_launch=false`, and required no-default text survey declarations for the dispatch ID and snapshot digest with exact 36- and 64-character bounds. These declarations form a dispatcher-owned allow-list and MUST NOT appear as user-facing ServiceRadar binding or run inputs. Because AWX does not hide survey questions, only the dedicated ServiceRadar runner identity SHALL have AWX Execute permission on hardened templates; ordinary operators SHALL NOT have a direct AWX launch path. Template edits SHALL be administrator-restricted and any edit SHALL require re-review before the binding becomes launchable again. A missing, broadened, defaulted, duplicated, or malformed marker declaration, or enabling the broad variable prompt, SHALL make the binding non-launchable. A binding SHALL also be non-launchable if AWX does not accept and the resulting job retain/echo the exact values. It SHALL activate a controller-local job binding only after the accepted job markers, template, inventory, literal limit, project/commit, execution environment, credentials, and mode match. On timeout, bounded recent-job enumeration SHALL be scoped by controller/template/inventory/launch window/integration identity and then compare the exact retained markers. Exactly one match may reconcile; zero/multiple become `dispatch_ambiguous`, MUST NOT be blindly retried, and cannot activate callbacks. If any child fails/ambiguous during parent dispatch, ServiceRadar SHALL stop undispatched children, cancel every accepted child, revoke prepared callbacks, and persist `dispatch_partial`; cancellation uncertainty additionally persists `cancel_failed`. Copied/relaunched jobs SHALL require a new authorized operation.

#### Scenario: AWX needs dispatcher markers but arbitrary variables remain closed
- **WHEN** an operator reviews an AWX 24.6.1 Job Template for hardened launch
- **THEN** its binding requires the exact restricted marker survey, keeps `ask_variables_on_launch` false, and excludes both marker names from user inputs
- **AND** AWX accepts only the two server-produced marker values plus separately reviewed survey fields rather than arbitrary `extra_vars`

#### Scenario: AWX acceptance is ambiguous
- **WHEN** dispatch times out after ServiceRadar cannot prove whether AWX accepted the launch
- **THEN** the child stops in `dispatch_ambiguous`, remains callback-inactive, and only an exact unique marker match can reconcile; otherwise candidates are canceled where possible

#### Scenario: Second child fails to dispatch
- **WHEN** one child has an accepted job and another child fails or becomes ambiguous during the same parent dispatch
- **THEN** ServiceRadar stops remaining children, cancels accepted jobs, revokes prepared callback state, and records `dispatch_partial` plus any `cancel_failed`

#### Scenario: One child cannot be canceled
- **WHEN** a parent cancellation succeeds for some AWX jobs but fails for another
- **THEN** the parent displays `cancel_failed`, continues reconciliation, and never reports full cancellation

#### Scenario: AWX copies a job
- **WHEN** a relaunch/copy lacks the exact local child and dispatch binding
- **THEN** ServiceRadar does not ingest it as the original operation or authorize its callbacks

### Requirement: Failed mutations create durable target holds
ServiceRadar SHALL derive authenticated `automation.mutation_phase.v1` only from AWX controller lifecycle for the exact bound child/job/host/action/template/revision over the mTLS edge command path; target stdout, `set_stats`, facts, inventory variables, and arbitrary event fields MUST NOT advance phase. Each outcome SHALL bind child, controller/inventory/AWX host ID, canonical device, transaction ID, generation, policy digest, phase, deadline, timestamp, and outcome digest. The allowed graph SHALL be `initial -> staged`; `staged -> verified | rolled_back | critical | unknown`; `verified -> committed | rolled_back | critical | unknown`; terminal `committed | rolled_back | critical | unknown` SHALL be immutable. Byte-identical replay under the same event/idempotency key SHALL be idempotent; conflicting replay, missing/invalid/out-of-order/unauthenticated evidence, or deadline expiry SHALL transition to `unknown`, never inferred success. ServiceRadar SHALL hold the canonical device when phase is critical/unknown, rollback cannot be proven, staged mutation expires, or authority contracts mid-mutation. The hold SHALL record triggering membership/transaction/generation and block every linked AWX membership. Clearing/reconciling SHALL require exact `ansible.targets.holds.clear`, administrator-only by default, applicable approval, current policy/evidence, attribution, and secret-free audit. Launch/cancel MUST NOT imply clearance. The public Ansible content supplies reviewed wrappers/diagnostics; the control plane owns phase derivation and durable quarantine.

#### Scenario: Rollback cannot be proven
- **WHEN** a staged SSH policy mutation fails and the prior reachable state cannot be verified
- **THEN** ServiceRadar holds the canonical device across all linked memberships and later mutating waves skip it

#### Scenario: Mutation phase evidence expires
- **WHEN** a staged transaction misses its deadline or supplies invalid/out-of-order/unauthenticated phase evidence
- **THEN** ServiceRadar records `unknown`, creates a device-wide hold, and never infers commit or rollback

#### Scenario: Operator clears a hold without evidence
- **WHEN** an actor requests hold clearance without the required permission/approval or current reconciliation evidence
- **THEN** ServiceRadar denies clearance and preserves the hold

#### Scenario: Launcher attempts to clear a hold
- **WHEN** an actor has ordinary launch/cancel permission but lacks `ansible.targets.holds.clear`
- **THEN** ServiceRadar preserves the hold and denies mutation for that target

#### Scenario: Read-only diagnostics are allowed
- **WHEN** policy permits a read-only preflight/verification against a held target
- **THEN** ServiceRadar may run the exact diagnostic without treating it as hold clearance or permitting mutation
