## Context

The partition-binding migration deliberately set every then-existing plugin assignment to `enabled = false` and `partition_id = NULL`. A current `ocsf_agents` row is not historical proof: an agent UID can re-enroll in a different partition. New assignments already derive `partition_id` from `AgentCommandBus.resolve_control_session_evidence/1`, but the package details view neither displays that fact nor has a recovery path for legacy rows.

The existing generic assignment form treats a legacy row as an ordinary existing assignment and follows the immutable update path. That cannot add a partition and therefore cannot re-enable the quarantined assignment safely.

## Goals / Non-Goals

### Goals

- Make the operator-visible partition provenance clear without allowing an operator to choose a partition.
- Recover only from a fresh, server-authenticated edge control session for the exact selected agent.
- Preserve a durable record of the legacy row and every recovery decision.
- Re-establish policy-owned assignments only through the policy that owns their configuration.
- Keep secret values out of the recovery API, UI, audit event, logs, and copied configuration; only existing secret references may be retained.

### Non-Goals

- Do not retroactively prove or mutate a historical legacy assignment's partition.
- Do not bulk-enable every legacy row based on a global `default` assumption.
- Do not add a general-purpose user-supplied `partition_id` to plugin assignment APIs.
- Do not treat a system actor as authorization evidence or allow it to perform a
  general user-triggered recovery without fresh reauthorization of the
  initiating principal.
- Do not treat a currently connected agent record or cached metadata as control-session evidence.

## Decisions

### Partition is a server-owned outcome, not form input

The assignment preflight endpoint may display a current authenticated partition for the selected agent, but it returns an informational preview only. At commit time the server resolves the control-session evidence again, checks the evidence agent UID, and writes the partition from that second result. The create/recovery action rejects caller-supplied partition data.

This prevents a user from using a form field, stale preview, or guessed default partition to route work into an identity boundary they have not authenticated.

### Manual legacy rows are cloned, never revived in place

An authorized reapproval command takes a legacy row ID and an explicit confirmation. In one transaction it:

1. reads and locks the legacy row in the caller's tenant scope;
2. verifies it is disabled and has no partition;
3. resolves current mTLS control-session evidence for the exact `agent_uid`;
4. checks the package remains approved, validates the copied configuration against the current schema, and checks active-assignment conflicts in the resolved partition;
5. creates a new manual assignment through the ordinary partition-binding create path; and
6. records an audit link from old row to new row, actor, authenticated principal tuple, decision, and timestamp.

The original row remains disabled and unbound. A retry is idempotent: a completed recovery returns its recorded replacement rather than creating a second enabled assignment. If a different enabled assignment now owns the same `(partition, agent, plugin)` tuple, the recovery fails with an actionable conflict and does not overwrite it.

Scheduling, timeout, permission/resource overrides, non-secret configuration, and secret references are candidates to copy. Raw secret values are never read or serialized. A missing newly-required configuration field causes a normal validation error, so an operator can make an intentional new configuration rather than silently changing behavior.

### Policy-owned rows are reconciled by their authoritative source

A legacy row with `source = :policy` is not a user-owned configuration snapshot. The UI identifies the source policy or credential rule and offers a scoped reconciliation request only when the actor is allowed to manage that source. The materializer re-evaluates current policy/rule eligibility, target resolution, package approval, and control-session evidence, then creates a fresh policy assignment if and only if all checks pass.

There is no manual "clone policy assignment" button. This avoids restoring outdated credentials, targets, or policy intent merely because a historical row exists.

Policy reconciliation is a durable request, not a fire-and-forget UI success.
After the caller has been authorized to read the particular legacy assignment in
its tenant, the recovery read model may obtain the newest request through a
named internal lookup and project only its safe state and replacement count.
That projection never contains request parameters, request or replacement IDs,
owner IDs, persisted principal details, credential data, or audit payloads.
The UI refreshes that assignment while a request is queued or running and shows
safe terminal remediation; it cannot enumerate recovery requests directly.

A credential-rule-owned row requires both plugin-assignment and
credential-management authority. The browser disables the reconciliation action
and explains the missing credential permission when applicable, but that is
only a usability guard: the requester is freshly reauthorized against the
current authoritative owner in the control plane before durable work begins.

The package index also exposes a tenant-scoped candidate review table with the
agent UID, plugin package reference, recovery kind, redacted status, and a link
to the package detail. It deliberately has no bulk restore action and never
suggests that `default` is an acceptable inferred partition.

### Policy fulfillment is constrained server work, not system authorization

Creating a credential-broker grant is intentionally a server-only operation.
After the restricted worker has claimed a durable request, it reauthorizes the
persisted initiating user or API-token principal in the tenant inside the
materialization transaction. Only then may a named server-only fulfillment actor
perform the necessary grant and assignment persistence for that one request.

The fulfillment actor is not authority evidence and receives no bearer token,
permission snapshot, caller parameters, or caller-selected partition. Its scope
is non-delegable and derived only from immutable request identifiers plus fresh
state: the current authoritative policy or credential rule, the one legacy
agent UID, and the exact mTLS-derived partition that is rechecked before and
after materialization. A failed reauthorization, source-authority check, lease,
or identity check prevents fulfillment and leaves the legacy row disabled.

Lease acquisition and terminalization are exact-executor, conditional database
updates rather than ordinary resource updates. A worker can claim only a
requested row or an expired lease, and can finish only its own unexpired lease
token. A stale or competing worker therefore affects no row, cannot dispatch
configuration, and cannot overwrite the durable outcome.

### Audit and authorization are first-class

Both preflight and recovery authorization execute in the current user/API-token
actor and tenant scope. A manual recovery requires the same assignment authority
as a new manual assignment. A policy reconciliation additionally requires the
authority governing that policy or credential rule before constrained server
fulfillment can occur. Every success, denial, conflict, and evidence-unavailable
result is auditable with identifiers and reasons but never raw secret material.

## Risks / Trade-offs

- A live session can change between UI preview and confirmation. Re-resolving evidence at commit protects the boundary; the UI may show a retryable "identity changed" result.
- Copying a legacy configuration can fail under a newer schema. Failing visibly is safer than silently dropping fields or manufacturing credentials.
- Some policy rows may no longer have a valid source rule. They remain disabled and are reported as unrecoverable until an operator recreates the policy intentionally.
- Recovery adds an audit relation/table or equivalent immutable audit event. This is more data than a direct update but makes a security-sensitive migration explainable and reversible at the operational level.
- Status refresh is intentionally a bounded UI convenience. The durable,
  tenant-scoped projection remains the source of truth, and an operator can
  refresh the package detail if a browser session ends before a terminal result.

## Migration Plan

1. Add domain/API support, audit storage, UI state, and tests behind the existing plugin-assignment authorization model.
2. Deploy without mutating legacy rows.
3. Operators use the tenant-scoped legacy candidate list to review each row,
   reapprove manual rows, and reconcile policy rows against their current
   authoritative rules. Credential-rule rows require credential-management
   authority in addition to plugin-assignment authority.
4. Observe assignment/service restoration and audit outcomes. Keep legacy rows until the product's normal retention policy permits archival.

Rollback disables only newly created replacement assignments through standard assignment controls; it never changes historical rows or infers their partition.

## Open Questions

- Whether the recovery audit should live in a dedicated assignment-recovery table or the existing immutable audit-event system will be selected during implementation after reviewing retention and query needs.
- The UI will use the current RBAC checks for assignment and credential-rule management; implementation will name the exact policy actions and document them for operators.
