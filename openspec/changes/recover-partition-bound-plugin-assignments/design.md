## Context

The partition-binding migration deliberately set every then-existing plugin assignment to `enabled = false` and `partition_id = NULL`. A current `ocsf_agents` row is not historical proof: an agent UID can re-enroll in a different partition. New assignments already derive `partition_id` from `AgentCommandBus.resolve_control_session_evidence/1`, but the package details view neither displays that fact nor has a recovery path for legacy rows.

The existing generic assignment form treats a legacy row as an ordinary existing assignment and follows the immutable update path. That cannot add a partition and therefore cannot re-enable the quarantined assignment safely.

The first recovery UI solved the database transition but exposed it directly to operators: every historical row became a separate review item, policy-owned desired state required a button click, package UUIDs were used as labels, and repeated warning panels were embedded in the ordinary assignment form. The security boundary is valid; the row-by-row workflow is not.

## Goals / Non-Goals

### Goals

- Make the operator-visible partition provenance clear without allowing an operator to choose a partition.
- Recover only from a fresh, server-authenticated edge control session for the exact selected agent.
- Automatically restore controller-owned desired state from its current authoritative policy or credential rule.
- Replace per-row manual work with one tenant-scoped, bounded recovery plan for compatible manual intent.
- Keep the normal assignment editor focused on current assignments and show only grouped, actionable recovery exceptions elsewhere.
- Preserve a durable record of the legacy row and every recovery decision.
- Re-establish policy-owned assignments only through the policy that owns their configuration.
- Keep secret values out of the recovery API, UI, audit event, logs, and copied configuration; only existing secret references may be retained.

### Non-Goals

- Do not retroactively prove or mutate a historical legacy assignment's partition.
- Do not indiscriminately bulk-enable legacy rows or use a global `default` assumption.
- Do not require operators to reconcile authoritative policy rows or approve the same recovery decision separately for every agent and package.
- Do not add a general-purpose user-supplied `partition_id` to plugin assignment APIs.
- Do not treat a system actor as authorization evidence for historical manual
  intent or allow it to perform a user-approved adoption plan without fresh
  reauthorization of the initiating principal. A narrowly scoped controller may
  materialize the current desired state of an enabled authoritative policy or
  credential rule under the same authority used for ordinary reconciliation.
- Do not treat a currently connected agent record or cached metadata as control-session evidence.

## Decisions

### Partition is a server-owned outcome, not form input

The assignment preflight endpoint may display a current authenticated partition for the selected agent, but it returns an informational preview only. At commit time the server resolves the control-session evidence again, checks the evidence agent UID, and writes the partition from that second result. The create/recovery action rejects caller-supplied partition data.

This prevents a user from using a form field, stale preview, or guessed default partition to route work into an identity boundary they have not authenticated.

### Recovery operates on logical desired state, not historical rows

The recovery planner groups legacy data by tenant, ownership source, agent UID,
and logical plugin. Duplicate historical rows contribute audit context but do
not become duplicate tasks or duplicate replacement assignments. Every planned
item has a stable fingerprint over its legacy source, current owner or manual
configuration, package schema, and target agent. Concurrent scans, reconnects,
and retries converge on the same item.

The planner runs after deployment and as a bounded background reconciliation on
agent connection, authoritative-owner changes, package approval/schema changes,
and a periodic safety sweep. Waiting for an offline agent is not an operator
exception; the item remains pending and retries when fresh session evidence is
available. Terminal or actionable failures are normalized into grouped reasons
such as incompatible configuration, invalid credential policy, unsupported
owner, permission denial, or active-assignment conflict.

### Manual legacy rows use one adoption plan and are never revived in place

The server builds a tenant-scoped adoption plan for compatible manual legacy
assignments. The preview shows recognizable plugin names, affected-agent counts,
and the number eligible, waiting, or blocked; it never exposes raw secret values
or asks the operator to reason about database rows. One authorized confirmation
approves all eligible items in that immutable plan. The confirmation is bounded
to its tenant, item fingerprints, initiating principal, and expiry and cannot be
used as a general assignment grant.

For every item, the executor:

1. reads and locks the plan item and legacy row in the initiating actor's tenant scope;
2. reauthorizes the persisted initiating principal and verifies the item fingerprint is unchanged;
3. resolves current mTLS control-session evidence for the exact `agent_uid`;
4. checks the package remains approved, validates the copied configuration against the current schema, and checks active-assignment conflicts in the resolved partition;
5. creates a new manual assignment through the ordinary partition-binding create path; and
6. records an audit link from old row to new row, actor, authenticated principal tuple, decision, and timestamp.

The original row remains disabled and unbound. A retry is idempotent: a completed recovery returns its recorded replacement rather than creating a second enabled assignment. If a different enabled assignment now owns the same `(partition, agent, plugin)` tuple, the recovery records an actionable conflict and does not overwrite it. A temporarily offline item remains attached to the approved plan and completes automatically on reconnect while the plan is valid. A changed fingerprint, expired plan, revoked initiating permission, or changed authenticated identity prevents fulfillment.

An operator may also create a genuinely new manual assignment through the
ordinary assignment form. Current-assignment lookup excludes every quarantined
unbound row, so stale history cannot intercept an update candidate or block
remove-and-recreate. The normal create path resolves fresh mTLS evidence and
performs its ordinary package, schema, authorization, policy-shadow, and conflict
checks; it never mutates or derives configuration from the historical row.

When immutable historical principal-continuity evidence independently binds a
legacy manual assignment to the current authenticated principal, the planner may
recover that item automatically with the same checks and audit. A matching agent
UID, current inventory row, cached partition, or connection alone is not
continuity evidence. Without that proof, the one tenant-scoped confirmation is
required.

Scheduling, timeout, permission/resource overrides, non-secret configuration, and secret references are candidates to copy. Raw secret values are never read or serialized. A missing newly-required configuration field causes a normal validation error, so an operator can make an intentional new configuration rather than silently changing behavior.

### Policy-owned rows reconcile automatically from their authoritative source

A legacy row with `source = :policy` is not a user-owned configuration snapshot. Its current enabled policy or credential rule is the desired state and already drives ordinary controller reconciliation. The recovery planner therefore schedules the current owner automatically, and the materializer re-evaluates current rule eligibility, target resolution, package approval, configuration schema, credential requirements, and control-session evidence. It creates a fresh policy assignment if and only if those current checks pass; no operator click or legacy configuration clone is involved.

Controller authority comes from the enabled current owner and the reconciler's
narrow internal action, not from the existence of a historical row and not from
a generic system actor. A browser-initiated change to the current policy or
credential rule still requires the user's normal assignment and credential
permissions. The automatic controller can materialize only the owner, targets,
configuration, and credential references that the current rule produces.

Some historical integration rows use an owner identifier that is not a current
plugin target policy or supported credential rule. That identifier is not
enough authority to invent a new materializer. The recovery read model marks
such a row as an unsupported policy owner, renders a non-actionable explanation,
and rejects forged reconciliation events. It stays disabled as history until an
operator creates an intentional replacement through a supported current owner.

After its terminal recovery status is durable, the executor seeds the normal
service-state placeholder from each fresh enabled assignment. That placeholder
uses the assignment's immutable `partition_id`, not inventory-derived agent
metadata. Agent metadata can lag or be overwritten when the same UID is seen
in another partition, and therefore cannot redirect a recovered service's
identity.

There is no manual "clone policy assignment" or "reconcile this row" button. This avoids restoring outdated credentials, targets, or policy intent merely because a historical row exists, and avoids making operators replay controller work.

Policy reconciliation is durable controller work. Its internal state is grouped
by logical desired assignment, not exposed as a global request queue or repeated
per historical row. The recovery summary may project only aggregate counts and
normalized exception reasons after tenant authorization. It never contains
request parameters, request or replacement IDs, owner IDs, persisted principal
details, credential data, or audit payloads.

### The UI is an exception console, not a migration work queue

The Plugins index shows a compact summary such as `18 restored automatically, 2
waiting for agents, 3 need attention`. Waiting items are informational and retry
without action. The exception view groups actionable items by recognizable
plugin name and remediation reason, shows affected-agent counts, and reveals
individual agents only on demand. Raw package UUIDs and recovery identifiers are
available only in technical detail.

Package details render only current live assignments in the normal assignment
editor. Historical rows and their audit outcome live in a collapsed history
section; repeated warning panels, per-row review links, and policy-reconcile
buttons are removed. An exception links directly to the owning credential rule,
policy, configuration editor, or conflict detail that can resolve it. The manual
adoption plan is the only recovery confirmation surface and summarizes the
entire tenant-scoped decision before the single confirmation.

### Automated fulfillment remains constrained server work

Creating a credential-broker grant is intentionally a server-only operation.
For a manual adoption plan, the restricted worker reauthorizes the persisted
initiating user or API-token principal in the tenant inside the materialization
transaction. For an automatic policy item, the worker instead verifies the
current enabled authoritative owner and executes the same narrow action used by
ordinary controller reconciliation. Only then may a named server-only
fulfillment actor perform the necessary grant and assignment persistence.

The fulfillment actor is not authority evidence and receives no bearer token,
permission snapshot, caller parameters, or caller-selected partition. Its scope
is non-delegable and derived only from immutable plan/controller identifiers plus
fresh state: the approved manual item or current authoritative owner, the one
agent UID, and the exact mTLS-derived partition rechecked before and after
materialization. Failed reauthorization, owner validation, lease, fingerprint,
schema, credential-policy, or identity checks prevent fulfillment and leave the
legacy row disabled.

Lease acquisition and terminalization are exact-executor, conditional database
updates rather than ordinary resource updates. A worker can claim only a
requested row or an expired lease, and can finish only its own unexpired lease
token. A stale or competing worker therefore affects no row, cannot dispatch
configuration, and cannot overwrite the durable outcome.

### Audit and authorization are first-class

Manual-plan preview and confirmation execute in the current user/API-token actor
and tenant scope and require the same assignment authority as new manual
assignments. Fulfillment reauthorizes that principal for each plan item. Automatic
policy recovery uses current controller authority and cannot be initiated or
parameterized by a browser event. Every success, denial, conflict, wait, and
evidence-unavailable result is auditable with identifiers and reasons but never
raw secret material. Detailed audit rows are internal; the user-facing summary
first authorizes the tenant and projects only allowlisted aggregate or exception
state.

## Risks / Trade-offs

- A live session can change between plan preview and fulfillment. Re-resolving evidence per item protects the boundary; the item waits or becomes an identity exception instead of routing to stale evidence.
- Copying a legacy configuration can fail under a newer schema. Failing visibly is safer than silently dropping fields or manufacturing credentials.
- Some policy rows may no longer have a valid source rule. They remain disabled and are reported as unrecoverable until an operator recreates the policy intentionally.
- Recovery adds an audit relation/table or equivalent immutable audit event. This is more data than a direct update but makes a security-sensitive migration explainable and reversible at the operational level.
- Automatic recovery can create a short burst of controller work after upgrade.
  Stable fingerprints, idempotent writes, bounded queues, reconnect triggers,
  and backoff keep that work convergent and observable.
- A tenant-wide manual plan authorizes more than one row at a time. Immutable
  membership, expiry, per-item reauthorization, current mTLS rechecks, schema and
  conflict validation, and item-level audit keep the approval bounded.

## Migration Plan

1. Add the logical recovery planner, controller triggers, manual adoption-plan authorization, aggregate projections, and tests behind the existing assignment boundary.
2. Deploy without mutating legacy rows. Start in report-only mode long enough to compare planned logical items with the quarantined inventory.
3. Enable automatic policy/credential-rule reconciliation and automatic retry for waiting agents. Current rule failures remain exceptions and never fall back to historical configuration.
4. Present one tenant-scoped confirmation for compatible manual items that lack immutable continuity evidence; complete eligible and subsequently reconnecting items from that bounded plan.
5. Replace the row-level UI and runbook with aggregate progress and grouped exception remediation. Validate restored service-state rows and active plugin execution in demo.
6. Keep legacy rows until the product's normal retention policy permits archival.

Rollback disables only newly created replacement assignments through standard assignment controls; it never changes historical rows or infers their partition.

## Open Questions

- The existing recovery request and audit tables should be extended into logical plan/item projections where practical; implementation will document any schema migration needed to avoid exposing one row per legacy record.
- The exact immutable evidence accepted for automatic manual continuity must be an explicit allowlist with tests. If no existing evidence qualifies, all manual rows use the single adoption plan rather than weakening the boundary.
