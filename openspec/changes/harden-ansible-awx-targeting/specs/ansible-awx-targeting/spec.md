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

#### Scenario: Controllers reuse a job ID
- **WHEN** two AWX controllers each return job ID `42`
- **THEN** ServiceRadar attributes each job/event only within its controller and child execution

#### Scenario: Duplicate runner host string appears
- **WHEN** child jobs report the same display host name for different host IDs
- **THEN** each result resolves through its child/inventory host ID and both outcomes are preserved

#### Scenario: Event target is unknown or ambiguous
- **WHEN** an event cannot be enriched to exactly one snapshotted AWX host ID or names an extra target
- **THEN** ServiceRadar records an attribution failure and does not apply it to a guessed target

### Requirement: Dispatch ambiguity and cancellation fail closed
ServiceRadar SHALL bind a unique dispatch nonce and full child snapshot before contacting AWX and add reserved typed non-secret launch `extra_vars` `serviceradar_dispatch_id` and `serviceradar_snapshot_digest`; users/catalog/surveys cannot set/override them. A binding SHALL be non-launchable if AWX does not accept and the resulting job retain/echo the exact values. It SHALL activate a controller-local job binding only after the accepted job markers, template, inventory, literal limit, project/commit, execution environment, credentials, and mode match. On timeout, bounded recent-job enumeration SHALL be scoped by controller/template/inventory/launch window/integration identity and then compare the exact retained markers. Exactly one match may reconcile; zero/multiple become `dispatch_ambiguous`, MUST NOT be blindly retried, and cannot activate callbacks. If any child fails/ambiguous during parent dispatch, ServiceRadar SHALL stop undispatched children, cancel every accepted child, revoke prepared callbacks, and persist `dispatch_partial`; cancellation uncertainty additionally persists `cancel_failed`. Copied/relaunched jobs SHALL require a new authorized operation.

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
